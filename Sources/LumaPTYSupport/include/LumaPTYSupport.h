#ifndef LUMA_PTY_SUPPORT_H
#define LUMA_PTY_SUPPORT_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A spawned PTY session. The caller owns `master_file_descriptor` and must
/// close it after the read side has been drained. `process_identifier` is also
/// the session/process-group leader created by forkpty(3).
typedef struct LumaPTYProcess {
    pid_t process_identifier;
    int master_file_descriptor;
} LumaPTYProcess;

/// All pointer storage must remain valid for the duration of
/// luma_pty_spawn(). `arguments` and `environment` must be NULL-terminated.
/// arguments[0] is required. A NULL working_directory keeps the current one.
typedef struct LumaPTYSpawnOptions {
    const char *executable_path;
    char *const *arguments;
    char *const *environment;
    const char *working_directory;
    uint16_t rows;
    uint16_t columns;
    uint16_t pixel_width;
    uint16_t pixel_height;
} LumaPTYSpawnOptions;

/// Identifies where a spawn failed. Child stages are delivered to the parent
/// through a close-on-exec pipe, so an execve(2) failure is never mistaken for
/// a successfully launched command.
typedef enum LumaPTYSpawnStage {
    LumaPTYSpawnStageNone = 0,
    LumaPTYSpawnStageValidation = 1,
    LumaPTYSpawnStageErrorPipe = 2,
    LumaPTYSpawnStageForkPTY = 3,
    LumaPTYSpawnStageChildDescriptorSetup = 4,
    LumaPTYSpawnStageChildChangeDirectory = 5,
    LumaPTYSpawnStageChildExec = 6,
    LumaPTYSpawnStageParentDescriptorSetup = 7,
    LumaPTYSpawnStageHandshake = 8,
    LumaPTYSpawnStageChildSignalSetup = 9
} LumaPTYSpawnStage;

typedef struct LumaPTYSpawnError {
    LumaPTYSpawnStage stage;
    int error_number;
} LumaPTYSpawnError;

/// Spawns executable_path under a new controlling PTY.
///
/// On success this returns 0 and fills out_process. The master descriptor is
/// O_NONBLOCK, FD_CLOEXEC, and F_SETNOSIGPIPE. On failure it returns -1, sets
/// errno and out_error, closes all intermediate descriptors, kills/reaps a
/// child if one was created, and leaves out_process invalid (-1/-1).
int luma_pty_spawn(
    const LumaPTYSpawnOptions *options,
    LumaPTYProcess *out_process,
    LumaPTYSpawnError *out_error
);

/// Applies a window size to the PTY master with TIOCSWINSZ.
int luma_pty_resize(
    int master_file_descriptor,
    uint16_t rows,
    uint16_t columns,
    uint16_t pixel_width,
    uint16_t pixel_height
);

/// Sends signal_number to the forkpty session leader's process group using
/// kill(-process_group_leader, signal_number). The leader must be > 1.
int luma_pty_signal_process_group(
    pid_t process_group_leader,
    int signal_number
);

/// Uses Darwin's TIOCSIG on the PTY master. Unlike signaling the original
/// session group, this asks the terminal driver to signal its current
/// foreground process group, including an interactive job that replaced it.
int luma_pty_signal_foreground_process_group(
    int master_file_descriptor,
    int signal_number
);

/// Observes whether the direct child has a final status without reaping it.
/// Returns 1 when exited/signaled, 0 while running, or -1 on error. Keeping the
/// child waitable prevents its PID/process-group identifier from being reused
/// while the caller performs descendant cleanup under its lifecycle lock.
int luma_pty_has_waitable_exit(pid_t process_identifier);

typedef struct LumaPTYProcessIdentity {
    pid_t process_identifier;
    uint64_t start_seconds;
    uint64_t start_microseconds;
} LumaPTYProcessIdentity;

/// Returns the exact current identity for pid, or -1 when it no longer exists.
int luma_pty_process_identity(
    pid_t process_identifier,
    LumaPTYProcessIdentity *out_identity
);

/// Lists bounded direct children with immutable start-time identities. The
/// return value is the number stored, or -1 on error.
int luma_pty_list_child_identities(
    pid_t parent_process_identifier,
    LumaPTYProcessIdentity *out_identities,
    int capacity
);

/// Lists processes still in the forkpty-created session, including job-control
/// groups other than the shell's original group.
int luma_pty_list_session_identities(
    pid_t session_identifier,
    LumaPTYProcessIdentity *out_identities,
    int capacity
);

/// Signals only when pid still has the recorded start-time identity. Returns 1
/// when signaled, 0 when the process disappeared/was reused, or -1 on error.
int luma_pty_signal_process_identity(
    const LumaPTYProcessIdentity *identity,
    int signal_number
);

typedef enum LumaPTYWaitKind {
    LumaPTYWaitKindUnknown = 0,
    LumaPTYWaitKindExited = 1,
    LumaPTYWaitKindSignaled = 2,
    LumaPTYWaitKindStopped = 3,
    LumaPTYWaitKindContinued = 4
} LumaPTYWaitKind;

typedef struct LumaPTYWaitStatus {
    LumaPTYWaitKind kind;
    int code;
    int raw_status;
    int core_dumped;
} LumaPTYWaitStatus;

/// Converts a waitpid(2) status word into a stable representation.
void luma_pty_normalize_wait_status(
    int raw_status,
    LumaPTYWaitStatus *out_status
);

/// Waits for a final child status. Returns 1 and fills out_status when a child
/// was reaped, 0 when nonblocking is nonzero and the child is still running,
/// or -1 on error. EINTR is retried internally.
int luma_pty_wait(
    pid_t process_identifier,
    int nonblocking,
    LumaPTYWaitStatus *out_status
);

#ifdef __cplusplus
}
#endif

#endif /* LUMA_PTY_SUPPORT_H */
