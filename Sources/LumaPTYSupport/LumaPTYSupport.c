#include "LumaPTYSupport.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

enum {
    LUMA_PTY_CHILD_ERROR_DESCRIPTOR = 3,
    LUMA_PTY_CHILD_FAILURE_EXIT_STATUS = 127
};

typedef struct LumaPTYChildErrorRecord {
    int stage;
    int error_number;
} LumaPTYChildErrorRecord;

static void luma_pty_initialize_outputs(
    LumaPTYProcess *out_process,
    LumaPTYSpawnError *out_error
) {
    if (out_process != NULL) {
        out_process->process_identifier = -1;
        out_process->master_file_descriptor = -1;
    }
    if (out_error != NULL) {
        out_error->stage = LumaPTYSpawnStageNone;
        out_error->error_number = 0;
    }
}

static int luma_pty_fail(
    LumaPTYSpawnStage stage,
    int error_number,
    LumaPTYSpawnError *out_error
) {
    if (out_error != NULL) {
        out_error->stage = stage;
        out_error->error_number = error_number;
    }
    errno = error_number;
    return -1;
}

static int luma_pty_set_close_on_exec(int descriptor) {
    int flags;
    do {
        flags = fcntl(descriptor, F_GETFD);
    } while (flags == -1 && errno == EINTR);
    if (flags == -1) {
        return -1;
    }

    int result;
    do {
        result = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC);
    } while (result == -1 && errno == EINTR);
    return result;
}

static int luma_pty_configure_master(int descriptor) {
    if (luma_pty_set_close_on_exec(descriptor) == -1) {
        return -1;
    }

    int status_flags;
    do {
        status_flags = fcntl(descriptor, F_GETFL);
    } while (status_flags == -1 && errno == EINTR);
    if (status_flags == -1) {
        return -1;
    }

    int result;
    do {
        result = fcntl(descriptor, F_SETFL, status_flags | O_NONBLOCK);
    } while (result == -1 && errno == EINTR);
    if (result == -1) {
        return -1;
    }

    do {
        result = fcntl(descriptor, F_SETNOSIGPIPE, 1);
    } while (result == -1 && errno == EINTR);
    return result;
}

static int luma_pty_child_close_limit(void) {
    struct rlimit descriptor_limit;
    if (getrlimit(RLIMIT_NOFILE, &descriptor_limit) == 0) {
        if (descriptor_limit.rlim_cur != RLIM_INFINITY) {
            if (descriptor_limit.rlim_cur > (rlim_t)INT_MAX) {
                return INT_MAX;
            }
            return (int)descriptor_limit.rlim_cur;
        }
    }

    long open_max = sysconf(_SC_OPEN_MAX);
    if (open_max > 0 && open_max < INT_MAX) {
        return (int)open_max;
    }
    return OPEN_MAX;
}

/// This routine is called only after forkpty has returned in the child. It
/// deliberately uses only async-signal-safe operations: write and _exit.
static void luma_pty_child_report_and_exit(
    int error_descriptor,
    LumaPTYSpawnStage stage,
    int error_number
) {
    LumaPTYChildErrorRecord record;
    record.stage = (int)stage;
    record.error_number = error_number;

    const unsigned char *bytes = (const unsigned char *)&record;
    size_t remaining = sizeof(record);
    while (remaining > 0) {
        ssize_t written = write(error_descriptor, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (size_t)written;
            continue;
        }
        if (written == -1 && errno == EINTR) {
            continue;
        }
        break;
    }
    _exit(LUMA_PTY_CHILD_FAILURE_EXIT_STATUS);
}

static void luma_pty_reap_after_spawn_failure(pid_t process_identifier) {
    int ignored_status;
    while (waitpid(process_identifier, &ignored_status, 0) == -1 && errno == EINTR) {
    }
}

static int luma_pty_read_child_error(
    int descriptor,
    LumaPTYChildErrorRecord *out_record
) {
    unsigned char *bytes = (unsigned char *)out_record;
    size_t received = 0;
    while (received < sizeof(*out_record)) {
        ssize_t count = read(descriptor, bytes + received, sizeof(*out_record) - received);
        if (count > 0) {
            received += (size_t)count;
            continue;
        }
        if (count == 0) {
            return received == 0 ? 0 : -2;
        }
        if (errno == EINTR) {
            continue;
        }
        return -1;
    }
    return 1;
}

int luma_pty_spawn(
    const LumaPTYSpawnOptions *options,
    LumaPTYProcess *out_process,
    LumaPTYSpawnError *out_error
) {
    luma_pty_initialize_outputs(out_process, out_error);
    if (options == NULL || out_process == NULL ||
        options->executable_path == NULL || options->executable_path[0] == '\0' ||
        options->arguments == NULL || options->arguments[0] == NULL ||
        options->environment == NULL || options->rows == 0 || options->columns == 0) {
        return luma_pty_fail(LumaPTYSpawnStageValidation, EINVAL, out_error);
    }

    int error_pipe[2] = {-1, -1};
    if (pipe(error_pipe) == -1) {
        return luma_pty_fail(LumaPTYSpawnStageErrorPipe, errno, out_error);
    }
    if (luma_pty_set_close_on_exec(error_pipe[0]) == -1 ||
        luma_pty_set_close_on_exec(error_pipe[1]) == -1) {
        int saved_error = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        return luma_pty_fail(LumaPTYSpawnStageErrorPipe, saved_error, out_error);
    }

    struct winsize window_size;
    memset(&window_size, 0, sizeof(window_size));
    window_size.ws_row = options->rows;
    window_size.ws_col = options->columns;
    window_size.ws_xpixel = options->pixel_width;
    window_size.ws_ypixel = options->pixel_height;
    int child_close_limit = luma_pty_child_close_limit();
    sigset_t empty_signal_mask;
    if (sigemptyset(&empty_signal_mask) == -1) {
        int saved_error = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        return luma_pty_fail(
            LumaPTYSpawnStageChildSignalSetup,
            saved_error,
            out_error
        );
    }

    int master_descriptor = -1;
    pid_t process_identifier = forkpty(
        &master_descriptor,
        NULL,
        NULL,
        &window_size
    );
    if (process_identifier == -1) {
        int saved_error = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        return luma_pty_fail(LumaPTYSpawnStageForkPTY, saved_error, out_error);
    }

    if (process_identifier == 0) {
        // forkpty has already installed the slave as descriptors 0, 1 and 2.
        // Reserve descriptor 3 for the close-on-exec error handshake, then
        // close the complete inherited descriptor range. close, dup2, fcntl,
        // chdir and execve are all async-signal-safe.
        close(error_pipe[0]);
        int child_error_descriptor = error_pipe[1];
        if (child_error_descriptor != LUMA_PTY_CHILD_ERROR_DESCRIPTOR) {
            if (dup2(child_error_descriptor, LUMA_PTY_CHILD_ERROR_DESCRIPTOR) == -1) {
                luma_pty_child_report_and_exit(
                    child_error_descriptor,
                    LumaPTYSpawnStageChildDescriptorSetup,
                    errno
                );
            }
            close(child_error_descriptor);
            child_error_descriptor = LUMA_PTY_CHILD_ERROR_DESCRIPTOR;
        }
        if (fcntl(child_error_descriptor, F_SETFD, FD_CLOEXEC) == -1) {
            luma_pty_child_report_and_exit(
                child_error_descriptor,
                LumaPTYSpawnStageChildDescriptorSetup,
                errno
            );
        }

        for (int descriptor = LUMA_PTY_CHILD_ERROR_DESCRIPTOR + 1;
             descriptor < child_close_limit;
             descriptor++) {
            close(descriptor);
        }

        // forkpty may run on a Swift/Dispatch worker whose thread signal mask
        // blocks interactive signals. execve preserves that mask, so clear it
        // in the now-single-threaded child using the async-signal-safe POSIX
        // primitive before entering sandbox-exec/the shell.
        if (sigprocmask(SIG_SETMASK, &empty_signal_mask, NULL) == -1) {
            luma_pty_child_report_and_exit(
                child_error_descriptor,
                LumaPTYSpawnStageChildSignalSetup,
                errno
            );
        }

        if (options->working_directory != NULL &&
            chdir(options->working_directory) == -1) {
            luma_pty_child_report_and_exit(
                child_error_descriptor,
                LumaPTYSpawnStageChildChangeDirectory,
                errno
            );
        }

        execve(
            options->executable_path,
            options->arguments,
            options->environment
        );
        luma_pty_child_report_and_exit(
            child_error_descriptor,
            LumaPTYSpawnStageChildExec,
            errno
        );
    }

    close(error_pipe[1]);
    if (luma_pty_configure_master(master_descriptor) == -1) {
        int saved_error = errno;
        close(error_pipe[0]);
        close(master_descriptor);
        kill(process_identifier, SIGKILL);
        luma_pty_reap_after_spawn_failure(process_identifier);
        return luma_pty_fail(
            LumaPTYSpawnStageParentDescriptorSetup,
            saved_error,
            out_error
        );
    }

    LumaPTYChildErrorRecord child_error;
    int handshake_result = luma_pty_read_child_error(error_pipe[0], &child_error);
    int handshake_error = errno;
    close(error_pipe[0]);
    if (handshake_result != 0) {
        if (handshake_result == 1) {
            handshake_error = child_error.error_number;
        } else if (handshake_result == -2) {
            handshake_error = EPROTO;
        }
        close(master_descriptor);
        kill(process_identifier, SIGKILL);
        luma_pty_reap_after_spawn_failure(process_identifier);
        return luma_pty_fail(
            handshake_result == 1
                ? (LumaPTYSpawnStage)child_error.stage
                : LumaPTYSpawnStageHandshake,
            handshake_error,
            out_error
        );
    }

    out_process->process_identifier = process_identifier;
    out_process->master_file_descriptor = master_descriptor;
    return 0;
}

int luma_pty_resize(
    int master_file_descriptor,
    uint16_t rows,
    uint16_t columns,
    uint16_t pixel_width,
    uint16_t pixel_height
) {
    if (master_file_descriptor < 0) {
        errno = EBADF;
        return -1;
    }
    struct winsize window_size;
    memset(&window_size, 0, sizeof(window_size));
    window_size.ws_row = rows;
    window_size.ws_col = columns;
    window_size.ws_xpixel = pixel_width;
    window_size.ws_ypixel = pixel_height;
    return ioctl(master_file_descriptor, TIOCSWINSZ, &window_size);
}

static int luma_pty_valid_signal(int signal_number, int allow_zero) {
    int minimum = allow_zero ? 0 : 1;
    return signal_number >= minimum && signal_number < NSIG;
}

int luma_pty_signal_process_group(
    pid_t process_group_leader,
    int signal_number
) {
    if (process_group_leader <= 1 || !luma_pty_valid_signal(signal_number, 1)) {
        errno = EINVAL;
        return -1;
    }
    return kill(-process_group_leader, signal_number);
}

int luma_pty_signal_foreground_process_group(
    int master_file_descriptor,
    int signal_number
) {
    if (master_file_descriptor < 0) {
        errno = EBADF;
        return -1;
    }
    if (!luma_pty_valid_signal(signal_number, 0)) {
        errno = EINVAL;
        return -1;
    }
    // TIOCSIG is an _IO request on Darwin: the signal is carried directly in
    // ioctl's scalar third argument rather than through an int pointer.
    return ioctl(master_file_descriptor, TIOCSIG, signal_number);
}

int luma_pty_has_waitable_exit(pid_t process_identifier) {
    if (process_identifier <= 1) {
        errno = EINVAL;
        return -1;
    }

    siginfo_t information;
    memset(&information, 0, sizeof(information));
    int result;
    do {
        result = waitid(
            P_PID,
            (id_t)process_identifier,
            &information,
            WEXITED | WNOHANG | WNOWAIT
        );
    } while (result == -1 && errno == EINTR);
    if (result == -1) {
        return -1;
    }
    return information.si_pid == process_identifier ? 1 : 0;
}

int luma_pty_process_identity(
    pid_t process_identifier,
    LumaPTYProcessIdentity *out_identity
) {
    if (process_identifier <= 1 || out_identity == NULL) {
        errno = EINVAL;
        return -1;
    }
    struct proc_bsdinfo information;
    memset(&information, 0, sizeof(information));
    int size = proc_pidinfo(
        process_identifier,
        PROC_PIDTBSDINFO,
        0,
        &information,
        (int)sizeof(information)
    );
    if (size != (int)sizeof(information) ||
        information.pbi_pid != (uint32_t)process_identifier) {
        if (size >= 0) {
            errno = ESRCH;
        }
        return -1;
    }
    out_identity->process_identifier = process_identifier;
    out_identity->start_seconds = information.pbi_start_tvsec;
    out_identity->start_microseconds = information.pbi_start_tvusec;
    return 0;
}

static int luma_pty_store_identity(
    pid_t process_identifier,
    LumaPTYProcessIdentity *out_identities,
    int count,
    int capacity
) {
    if (count >= capacity) {
        return count;
    }
    LumaPTYProcessIdentity identity;
    if (luma_pty_process_identity(process_identifier, &identity) == 0) {
        out_identities[count] = identity;
        return count + 1;
    }
    return count;
}

int luma_pty_list_child_identities(
    pid_t parent_process_identifier,
    LumaPTYProcessIdentity *out_identities,
    int capacity
) {
    if (parent_process_identifier <= 1 || out_identities == NULL || capacity <= 0) {
        errno = EINVAL;
        return -1;
    }
    enum { LUMA_PTY_MAX_ENUMERATED_PROCESSES = 4096 };
    pid_t identifiers[LUMA_PTY_MAX_ENUMERATED_PROCESSES];
    int listed = proc_listchildpids(
        parent_process_identifier,
        identifiers,
        (int)sizeof(identifiers)
    );
    if (listed < 0) {
        return -1;
    }
    int available = listed > LUMA_PTY_MAX_ENUMERATED_PROCESSES
        ? LUMA_PTY_MAX_ENUMERATED_PROCESSES
        : listed;
    int count = 0;
    for (int index = 0; index < available && count < capacity; index++) {
        if (identifiers[index] > 1) {
            count = luma_pty_store_identity(
                identifiers[index],
                out_identities,
                count,
                capacity
            );
        }
    }
    return count;
}

int luma_pty_list_session_identities(
    pid_t session_identifier,
    LumaPTYProcessIdentity *out_identities,
    int capacity
) {
    if (session_identifier <= 1 || out_identities == NULL || capacity <= 0) {
        errno = EINVAL;
        return -1;
    }
    enum { LUMA_PTY_MAX_ENUMERATED_PROCESSES = 4096 };
    pid_t identifiers[LUMA_PTY_MAX_ENUMERATED_PROCESSES];
    int count_all = proc_listallpids(identifiers, (int)sizeof(identifiers));
    if (count_all < 0) {
        return -1;
    }
    int count = 0;
    int available = count_all > LUMA_PTY_MAX_ENUMERATED_PROCESSES
        ? LUMA_PTY_MAX_ENUMERATED_PROCESSES
        : count_all;
    for (int index = 0; index < available && count < capacity; index++) {
        pid_t candidate = identifiers[index];
        if (candidate > 1 && getsid(candidate) == session_identifier) {
            count = luma_pty_store_identity(
                candidate,
                out_identities,
                count,
                capacity
            );
        }
    }
    return count;
}

int luma_pty_signal_process_identity(
    const LumaPTYProcessIdentity *identity,
    int signal_number
) {
    if (identity == NULL || identity->process_identifier <= 1 || signal_number < 0) {
        errno = EINVAL;
        return -1;
    }
    LumaPTYProcessIdentity current;
    if (luma_pty_process_identity(identity->process_identifier, &current) == -1) {
        return errno == ESRCH ? 0 : -1;
    }
    if (current.start_seconds != identity->start_seconds ||
        current.start_microseconds != identity->start_microseconds) {
        return 0;
    }
    if (kill(identity->process_identifier, signal_number) == 0) {
        return 1;
    }
    return errno == ESRCH ? 0 : -1;
}

void luma_pty_normalize_wait_status(
    int raw_status,
    LumaPTYWaitStatus *out_status
) {
    if (out_status == NULL) {
        return;
    }
    out_status->kind = LumaPTYWaitKindUnknown;
    out_status->code = 0;
    out_status->raw_status = raw_status;
    out_status->core_dumped = 0;

    if (WIFEXITED(raw_status)) {
        out_status->kind = LumaPTYWaitKindExited;
        out_status->code = WEXITSTATUS(raw_status);
        return;
    }
    if (WIFSIGNALED(raw_status)) {
        out_status->kind = LumaPTYWaitKindSignaled;
        out_status->code = WTERMSIG(raw_status);
#ifdef WCOREDUMP
        out_status->core_dumped = WCOREDUMP(raw_status) ? 1 : 0;
#endif
        return;
    }
    if (WIFSTOPPED(raw_status)) {
        out_status->kind = LumaPTYWaitKindStopped;
        out_status->code = WSTOPSIG(raw_status);
        return;
    }
#ifdef WIFCONTINUED
    if (WIFCONTINUED(raw_status)) {
        out_status->kind = LumaPTYWaitKindContinued;
    }
#endif
}

int luma_pty_wait(
    pid_t process_identifier,
    int nonblocking,
    LumaPTYWaitStatus *out_status
) {
    if (process_identifier <= 0 || out_status == NULL) {
        errno = EINVAL;
        return -1;
    }

    int raw_status;
    pid_t result;
    int options = nonblocking ? WNOHANG : 0;
    do {
        result = waitpid(process_identifier, &raw_status, options);
    } while (result == -1 && errno == EINTR);
    if (result == -1) {
        return -1;
    }
    if (result == 0) {
        return 0;
    }

    luma_pty_normalize_wait_status(raw_status, out_status);
    return 1;
}
