import Foundation

enum RemoteWorkspaceTransferDirection: String, Codable, Sendable {
    case localToRemote = "local_to_remote"
    case remoteToLocal = "remote_to_local"
    case rollbackRemote = "rollback_remote"
}

enum RemoteWorkspaceNodeKind: String, Codable, Sendable {
    case absent
    case directory
    case regularFile = "regular_file"
}

struct RemoteWorkspaceStateNode: Codable, Equatable, Sendable {
    var relativePath: String
    var kind: RemoteWorkspaceNodeKind
    var data: Data?
    var permissions: Int?
}

/// A deliberately bounded, language-neutral wire representation of the Git
/// state used by Local/Worktree <-> SSH handoff. It contains no `.git`
/// internals, credentials, absolute destination path, or arbitrary ignored
/// files. AppleDouble entries are never represented or mutated.
struct RemoteWorkspaceStateSnapshot: Codable, Equatable, Sendable {
    static let maximumWireBytes = 4 * 1_024 * 1_024
    static let maximumTransactionWireBytes = 8 * 1_024 * 1_024
    static let maximumContentBytes = 3 * 1_024 * 1_024
    static let maximumFiles = 2_048
    static let maximumPathBytes = 256 * 1_024

    var sourceRootPath: String
    var headObjectID: String
    var symbolicReference: String?
    var workingTreePatch: Data
    var stagedPatch: Data
    var supplementalManifest: [RemoteWorkspaceStateNode]
    var supplementalRoots: [String]

    init(
        sourceRootPath: String,
        headObjectID: String,
        symbolicReference: String? = nil,
        workingTreePatch: Data,
        stagedPatch: Data,
        supplementalManifest: [RemoteWorkspaceStateNode],
        supplementalRoots: [String]
    ) {
        self.sourceRootPath = sourceRootPath
        self.headObjectID = headObjectID
        self.symbolicReference = symbolicReference
        self.workingTreePatch = workingTreePatch
        self.stagedPatch = stagedPatch
        self.supplementalManifest = supplementalManifest
        self.supplementalRoots = supplementalRoots
    }

    init(_ snapshot: WorktreeStateSnapshot) {
        sourceRootPath = snapshot.sourceRootPath
        headObjectID = snapshot.headObjectID
        symbolicReference = snapshot.symbolicReference
        workingTreePatch = snapshot.workingTreePatch
        stagedPatch = snapshot.stagedPatch
        supplementalManifest = snapshot.supplementalManifest.map { entry in
            let kind: RemoteWorkspaceNodeKind
            switch entry.kind {
            case .absent: kind = .absent
            case .directory: kind = .directory
            case .regularFile: kind = .regularFile
            }
            return RemoteWorkspaceStateNode(
                relativePath: entry.relativePath,
                kind: kind,
                data: entry.data,
                permissions: entry.permissions
            )
        }
        supplementalRoots = snapshot.supplementalRoots
    }

    func validated() throws -> RemoteWorkspaceStateSnapshot {
        var result = self
        result.sourceRootPath = try RemotePathPolicy.absoluteWorkspaceRoot(sourceRootPath)
        guard Self.isObjectID(headObjectID) else {
            throw RemoteExecutionError.protocolViolation(
                "Remote migration HEAD is not a Git object ID."
            )
        }
        guard workingTreePatch.count <= Self.maximumContentBytes,
              stagedPatch.count <= Self.maximumContentBytes,
              workingTreePatch.count <= Self.maximumContentBytes - stagedPatch.count,
              supplementalManifest.count <= Self.maximumFiles,
              supplementalRoots.count <= Self.maximumFiles else {
            throw RemoteExecutionError.invalidRequest(
                "Remote migration exceeds the bounded transfer contract."
            )
        }

        var totalPathBytes = 0
        var contentBytes = workingTreePatch.count + stagedPatch.count
        var seenNodes = Set<String>()
        for index in result.supplementalRoots.indices {
            let path = try Self.validatedMigrationPath(result.supplementalRoots[index])
            result.supplementalRoots[index] = path
            totalPathBytes += path.utf8.count
        }
        guard Set(result.supplementalRoots).count == result.supplementalRoots.count else {
            throw RemoteExecutionError.invalidRequest(
                "Remote migration contains duplicate supplemental roots."
            )
        }

        for index in result.supplementalManifest.indices {
            var node = result.supplementalManifest[index]
            node.relativePath = try Self.validatedMigrationPath(node.relativePath)
            guard seenNodes.insert(node.relativePath).inserted else {
                throw RemoteExecutionError.invalidRequest(
                    "Remote migration contains duplicate manifest paths."
                )
            }
            totalPathBytes += node.relativePath.utf8.count
            switch node.kind {
            case .absent:
                guard node.data == nil, node.permissions == nil else {
                    throw RemoteExecutionError.protocolViolation(
                        "An absent migration node contains file metadata."
                    )
                }
            case .directory:
                guard node.data == nil,
                      let permissions = node.permissions,
                      (0...0o777).contains(permissions) else {
                    throw RemoteExecutionError.protocolViolation(
                        "A migration directory has invalid metadata."
                    )
                }
            case .regularFile:
                guard let data = node.data,
                      let permissions = node.permissions,
                      (0...0o777).contains(permissions) else {
                    throw RemoteExecutionError.protocolViolation(
                        "A migration file has invalid metadata."
                    )
                }
                guard data.count <= Self.maximumContentBytes,
                      contentBytes <= Self.maximumContentBytes - data.count else {
                    throw RemoteExecutionError.invalidRequest(
                        "Remote migration file contents exceed the transfer limit."
                    )
                }
                contentBytes += data.count
            }
            result.supplementalManifest[index] = node
        }
        guard totalPathBytes <= Self.maximumPathBytes else {
            throw RemoteExecutionError.invalidRequest(
                "Remote migration path manifest is too large."
            )
        }
        let encoded = try JSONEncoder().encode(result)
        guard encoded.count <= Self.maximumWireBytes else {
            throw RemoteExecutionError.invalidRequest(
                "Encoded remote migration exceeds 4 MiB."
            )
        }
        return result
    }

    var fingerprint: String {
        worktreeSnapshot.fingerprint
    }

    var isClean: Bool {
        workingTreePatch.isEmpty
            && stagedPatch.isEmpty
            && supplementalManifest.allSatisfy {
                $0.kind == .absent || $0.kind == .directory
            }
    }

    var worktreeSnapshot: WorktreeStateSnapshot {
        let manifest = supplementalManifest.map { node -> WorktreeSupplementalPath in
            let kind: WorktreeSupplementalPathKind
            switch node.kind {
            case .absent: kind = .absent
            case .directory: kind = .directory
            case .regularFile: kind = .regularFile
            }
            return WorktreeSupplementalPath(
                relativePath: node.relativePath,
                kind: kind,
                data: node.data,
                permissions: node.permissions
            )
        }
        return WorktreeStateSnapshot(
            sourceRootPath: sourceRootPath,
            headObjectID: headObjectID,
            symbolicReference: symbolicReference,
            workingTreePatch: workingTreePatch,
            stagedPatch: stagedPatch,
            supplementalFiles: manifest.compactMap { entry in
                guard entry.kind == .regularFile,
                      let data = entry.data,
                      let permissions = entry.permissions else { return nil }
                return WorktreeSupplementalFile(
                    relativePath: entry.relativePath,
                    data: data,
                    permissions: permissions
                )
            },
            supplementalManifest: manifest,
            supplementalRoots: supplementalRoots
        )
    }

    static func validatedMigrationPath(_ value: String) throws -> String {
        let path = try RemotePathPolicy.relative(value, allowRoot: false)
        try RemotePathPolicy.refusesAppleDoubleMutation(path)
        guard !path.split(separator: "/").contains(".git") else {
            throw RemoteExecutionError.invalidRequest(
                "Git administrative paths cannot be migrated."
            )
        }
        return path
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 97 && $0.value <= 102)
        }
    }
}

struct RemoteWorkspaceStateCapture: Equatable, Sendable {
    var snapshot: RemoteWorkspaceStateSnapshot
    var receipt: RemoteOperationReceipt
}

struct RemoteWorkspaceTransferReceipt: Equatable, Sendable {
    var direction: RemoteWorkspaceTransferDirection
    var snapshotFingerprint: String
    var operation: RemoteOperationReceipt
}

protocol RemoteWorkspaceStateBackend: Sendable {
    func captureWorkspaceState(
        supplementalPaths: [String]
    ) async throws -> RemoteWorkspaceStateCapture

    func applyWorkspaceState(
        _ snapshot: RemoteWorkspaceStateSnapshot,
        expectedBaseline: RemoteWorkspaceStateSnapshot,
        transactionID: UUID
    ) async throws -> RemoteWorkspaceTransferReceipt

    /// Idempotently restores the clean same-HEAD destination, but only when
    /// the destination is still byte-for-byte equal to `expectedApplied`.
    func rollbackWorkspaceState(
        expectedApplied: RemoteWorkspaceStateSnapshot,
        restoring baseline: RemoteWorkspaceStateSnapshot,
        transactionID: UUID
    ) async throws -> RemoteWorkspaceTransferReceipt
}

struct RemoteWorkspaceMigrationPreparation: Sendable {
    var desired: RemoteWorkspaceStateSnapshot
    var remoteBaseline: RemoteWorkspaceStateSnapshot
    var remoteCaptureReceipt: RemoteOperationReceipt
}

/// Host-owned orchestration shared by Desktop now and the Phase-G App Server
/// later. The model never receives a host/path selector and cannot invoke this
/// primitive as a normal tool.
struct RemoteWorkspaceMigrationService: Sendable {
    private let localMigrator: WorktreeStateMigrator

    init(localMigrator: WorktreeStateMigrator = WorktreeStateMigrator()) {
        self.localMigrator = localMigrator
    }

    func prepareLocalToRemote(
        sourceRoot: URL,
        supplementalPaths: [String],
        backend: any RemoteWorkspaceStateBackend
    ) async throws -> RemoteWorkspaceMigrationPreparation {
        let validatedPaths = try supplementalPaths.map(
            RemoteWorkspaceStateSnapshot.validatedMigrationPath
        )
        try await Self.refuseTrackedAppleDouble(in: sourceRoot)
        let local = try await localMigrator.capture(
            sourceRoot: sourceRoot,
            supplementalPaths: validatedPaths
        )
        let desired = try RemoteWorkspaceStateSnapshot(local).validated()
        let remote = try await backend.captureWorkspaceState(
            supplementalPaths: desired.supplementalRoots
        )
        let baseline = try remote.snapshot.validated()
        guard baseline.isClean else {
            throw WorktreeStateMigrationError.targetNotClean(baseline.sourceRootPath)
        }
        guard baseline.headObjectID == desired.headObjectID else {
            throw WorktreeStateMigrationError.revisionMismatch(
                source: desired.headObjectID,
                target: baseline.headObjectID
            )
        }
        return RemoteWorkspaceMigrationPreparation(
            desired: desired,
            remoteBaseline: baseline,
            remoteCaptureReceipt: remote.receipt
        )
    }

    func captureRemote(
        supplementalPaths: [String],
        backend: any RemoteWorkspaceStateBackend
    ) async throws -> RemoteWorkspaceStateCapture {
        let paths = try supplementalPaths.map(
            RemoteWorkspaceStateSnapshot.validatedMigrationPath
        )
        return try await backend.captureWorkspaceState(supplementalPaths: paths)
    }

    private static func refuseTrackedAppleDouble(in root: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = [
                "--literal-pathspecs", "-C", root.standardizedFileURL.path,
                "ls-files", "-z", "--"
            ]
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "LC_ALL": "C",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_TERMINAL_PROMPT": "0"
            ]
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw WorktreeStateMigrationError.commandFailed(
                    String(decoding: errorData.prefix(2_048), as: UTF8.self)
                )
            }
            guard data.count <= WorktreeStateMigrator.maximumPathListBytes else {
                throw WorktreeStateMigrationError.outputTooLarge(
                    WorktreeStateMigrator.maximumPathListBytes
                )
            }
            for raw in data.split(separator: 0) {
                guard let path = String(data: Data(raw), encoding: .utf8) else {
                    throw WorktreeStateMigrationError.unsafePath("non-UTF-8 Git path")
                }
                if path.split(separator: "/").contains(where: { $0.hasPrefix("._") }) {
                    throw WorktreeStateMigrationError.unsafePath(
                        "AppleDouble entries cannot participate in Remote Handoff"
                    )
                }
            }
        }.value
    }
}

struct RemoteWorkspaceMigrationWire {
    struct CaptureRequest: Encodable {
        var supplementalPaths: [String]
    }

    struct Acknowledgement: Decodable {
        var status: String
        var headObjectID: String
    }

    struct TransactionRequest: Encodable {
        var transactionID: String
        var desired: RemoteWorkspaceStateSnapshot
        var baseline: RemoteWorkspaceStateSnapshot
    }

    /// One fixed host-owned program implements capture/apply/rollback. Model
    /// text is never interpolated into it; paths and payload arrive as bounded
    /// JSON on stdin and every filesystem component is lstat-checked.
    static let program = #"""
import base64,ctypes,errno,json,os,secrets,selectors,stat,subprocess,sys
op,root=sys.argv[1],os.path.realpath(sys.argv[2])
MAX_SNAPSHOT=4*1024*1024
MAX_TRANSACTION=8*1024*1024
MAX_CONTENT=3*1024*1024
MAX_FILES=2048
MAX_PATH_BYTES=256*1024
def die(message,code=64):
    print(message,file=sys.stderr);sys.exit(code)
if root=="/" or not os.path.isabs(root):die("remote workspace is unavailable")
try:root_fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
except OSError:die("remote workspace cannot be opened safely")
root_info=os.fstat(root_fd)
if not stat.S_ISDIR(root_info.st_mode):die("remote workspace is not a directory")
git_executable="/usr/bin/git" if os.path.isfile("/usr/bin/git") else "/bin/git"
if not os.path.isfile(git_executable):die("Git is unavailable on the remote host")
git_environment={"PATH":"/usr/bin:/bin","LC_ALL":"C","LANG":"C","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":"/dev/null","GIT_TERMINAL_PROMPT":"0"}
def require_root_identity():
    try:current=os.stat(root,follow_symlinks=False)
    except OSError:die("remote workspace path changed",75)
    if current.st_dev!=root_info.st_dev or current.st_ino!=root_info.st_ino or not stat.S_ISDIR(current.st_mode):die("remote workspace identity changed",75)
def git(args,input_data=None,limit=MAX_CONTENT):
    require_root_identity()
    process=subprocess.Popen([git_executable,"--literal-pathspecs","-C",root]+args,stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=git_environment)
    selector=selectors.DefaultSelector();stdout=bytearray();stderr=bytearray();input_offset=0
    def register(stream,events,label):
        os.set_blocking(stream.fileno(),False);selector.register(stream,events,label)
    register(process.stdout,selectors.EVENT_READ,"stdout");register(process.stderr,selectors.EVENT_READ,"stderr")
    if input_data is not None:
        if input_data:register(process.stdin,selectors.EVENT_WRITE,"stdin")
        else:process.stdin.close()
    while selector.get_map():
        try:events=selector.select()
        except InterruptedError:continue
        for key,_ in events:
            stream=key.fileobj;label=key.data
            if label=="stdin":
                try:written=os.write(stream.fileno(),input_data[input_offset:input_offset+65536])
                except (BlockingIOError,InterruptedError):continue
                except BrokenPipeError:written=0;input_offset=len(input_data)
                if written>0:input_offset+=written
                if input_offset>=len(input_data):
                    selector.unregister(stream);stream.close()
            else:
                try:chunk=os.read(stream.fileno(),65536)
                except (BlockingIOError,InterruptedError):continue
                if chunk:
                    target=stdout if label=="stdout" else stderr
                    maximum=limit+1 if label=="stdout" else 2049
                    if len(target)<maximum:target.extend(chunk[:maximum-len(target)])
                else:
                    selector.unregister(stream);stream.close()
    result_code=process.wait()
    require_root_identity()
    if result_code!=0:die(bytes(stderr or stdout)[:2048].decode("utf-8","replace"))
    if len(stdout)>limit:die("remote Git state exceeds transfer bound")
    return bytes(stdout)
def decode_paths(data):
    result=[]
    for item in data.split(b"\0"):
        if not item:continue
        try:result.append(item.decode("utf-8"))
        except UnicodeDecodeError:die("non-UTF-8 Git paths cannot migrate")
    return result
def apple(path):return any(part.startswith("._") for part in path.split("/"))
def valid(path):
    if not isinstance(path,str) or not path or path.startswith("/") or "\0" in path:die("invalid migration path")
    values=path.split("/")
    if any(not value or value in (".","..") for value in values):die("non-normal migration path")
    if ".git" in values:die("Git administrative paths cannot migrate")
    if apple(path):die("AppleDouble paths cannot migrate")
    if len(path.encode("utf-8"))>4096:die("migration path is too long")
    return path
def parts(path):return valid(path).split("/")
def signature(info):
    return (info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_ctime_ns,info.st_uid,info.st_gid,info.st_nlink)
def open_directory(values):
    descriptor=os.dup(root_fd)
    try:
        for value in values:
            next_descriptor=os.open(value,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptor)
            os.close(descriptor);descriptor=next_descriptor
        return descriptor
    except BaseException:
        try:os.close(descriptor)
        except OSError:pass
        raise
def parent_and_name(path):
    values=parts(path)
    return open_directory(values[:-1]),values[-1]
def open_target(path):
    parent,name=parent_and_name(path)
    try:return os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
    finally:os.close(parent)
def node_map(value):return {node["relativePath"]:node for node in value.get("supplementalManifest",[])}
def absent_node(path):return {"relativePath":path,"kind":"absent"}
def effective_node(values,path):return values.get(path,absent_node(path))
def tracked_paths():
    values=decode_paths(git(["ls-files","-z","--"],limit=8*1024*1024))
    values+=decode_paths(git(["ls-tree","-r","--name-only","-z","HEAD","--"],limit=8*1024*1024))
    if any(apple(path) for path in values):die("tracked AppleDouble entries prohibit migration")
    return set(values)
def untracked_paths():
    values=decode_paths(git(["ls-files","--others","--exclude-standard","-z","--"],limit=8*1024*1024))
    return [path for path in values if not apple(path)]
def tracked_capture():
    head=git(["rev-parse","--verify","HEAD"],limit=256).decode("ascii").strip()
    if len(head) not in (40,64) or any(value not in "0123456789abcdef" for value in head):die("invalid HEAD")
    working=git(["diff","--binary","--full-index","--no-ext-diff","--no-textconv","HEAD","--"])
    staged=git(["diff","--cached","--binary","--full-index","--no-ext-diff","--no-textconv","HEAD","--"])
    return head,working,staged
def symbolic_reference():
    value=git(["rev-parse","--symbolic-full-name","HEAD"],limit=4096).decode("utf-8","strict").strip()
    if value=="HEAD" or not value.startswith("refs/heads/"):return None
    if len(value.encode("utf-8"))>4096:die("remote symbolic reference exceeds bounds")
    return value
top=git(["rev-parse","--show-toplevel"],limit=4096).decode("utf-8","strict").strip()
if os.path.realpath(top)!=root:die("remote workspace must be the Git repository top-level")
def capture(requested_paths):
    require_root_identity()
    requested_paths=[valid(value) for value in requested_paths]
    if len(requested_paths)>MAX_FILES or len(set(requested_paths))!=len(requested_paths) or sum(len(value.encode("utf-8")) for value in requested_paths)>MAX_PATH_BYTES:die("supplemental roots exceed bounds")
    head,working,staged=tracked_capture();tracked=tracked_paths();untracked=untracked_paths()
    symbolic=symbolic_reference()
    roots=[]
    for value in untracked+requested_paths:
        valid(value)
        if value not in roots:roots.append(value)
    manifest={};observed={};walked=set();content=[len(working)+len(staged)]
    def put(node,info=None):
        path=node["relativePath"]
        if path in manifest and manifest[path]!=node:die("migration path changed during capture")
        manifest[path]=node
        if info is not None:observed[path]=signature(info)
        elif node["kind"]=="absent":observed[path]=None
        if len(manifest)>MAX_FILES:die("remote migration file count exceeds bounds")
    def inspect_parent_directories(path):
        values=parts(path);prefix=[]
        for value in values[:-1]:
            prefix.append(value);relative="/".join(prefix)
            if any(item==relative or item.startswith(relative+"/") for item in tracked):continue
            try:descriptor=open_target(relative)
            except FileNotFoundError:return
            except OSError:die("unsafe migration parent")
            try:
                info=os.fstat(descriptor)
                if not stat.S_ISDIR(info.st_mode):die("unsafe migration parent")
                put({"relativePath":relative,"kind":"directory","permissions":stat.S_IMODE(info.st_mode)},info)
            finally:os.close(descriptor)
    def visit(path,explicit=False):
        valid(path)
        if path in tracked:return
        if path in walked:return
        walked.add(path)
        try:descriptor=open_target(path)
        except FileNotFoundError:
            if explicit:put(absent_node(path))
            return
        except OSError:die("symbolic links or unsafe nodes cannot migrate")
        try:
            before=os.fstat(descriptor)
            if stat.S_ISREG(before.st_mode):
                chunks=[];remaining=MAX_CONTENT+1
                while remaining:
                    chunk=os.read(descriptor,min(65536,remaining))
                    if not chunk:break
                    chunks.append(chunk);remaining-=len(chunk)
                after=os.fstat(descriptor)
                if signature(before)!=signature(after):die("migration file changed during capture")
                data=b"".join(chunks);content[0]+=len(data)
                if len(data)>MAX_CONTENT or content[0]>MAX_CONTENT:die("remote migration contents exceed bounds")
                put({"relativePath":path,"kind":"regular_file","data":base64.b64encode(data).decode("ascii"),"permissions":stat.S_IMODE(after.st_mode)},after)
            elif stat.S_ISDIR(before.st_mode):
                names=sorted(os.listdir(descriptor));after=os.fstat(descriptor)
                if signature(before)!=signature(after):die("migration directory changed during capture")
                put({"relativePath":path,"kind":"directory","permissions":stat.S_IMODE(after.st_mode)},after)
                for name in names:
                    nested=path+"/"+name
                    if apple(nested):continue
                    visit(nested,True)
            else:die("symbolic links and special files cannot migrate")
        finally:os.close(descriptor)
    explicit=set(requested_paths)
    for value in roots:inspect_parent_directories(value)
    for value in roots:visit(value,value in explicit)
    final_head,final_working,final_staged=tracked_capture();final_symbolic=symbolic_reference()
    if (head,working,staged,symbolic)!=(final_head,final_working,final_staged,final_symbolic) or tracked!=tracked_paths() or untracked!=untracked_paths():die("remote Git state changed during capture",75)
    for path,expected in observed.items():
        try:descriptor=open_target(path)
        except FileNotFoundError:
            if expected is None:continue
            die("remote supplemental state changed during capture",75)
        except OSError:die("remote supplemental state became unsafe",75)
        try:
            if expected is None or signature(os.fstat(descriptor))!=expected:die("remote supplemental state changed during capture",75)
        finally:os.close(descriptor)
    result={"sourceRootPath":root,"headObjectID":head,"workingTreePatch":base64.b64encode(working).decode("ascii"),"stagedPatch":base64.b64encode(staged).decode("ascii"),"supplementalManifest":[manifest[key] for key in sorted(manifest)],"supplementalRoots":roots}
    if symbolic is not None:result["symbolicReference"]=symbolic
    encoded=json.dumps(result,separators=(",",":"),sort_keys=True).encode("utf-8")
    if len(encoded)>MAX_SNAPSHOT:die("encoded remote state exceeds 4 MiB")
    require_root_identity()
    return result
def validate_snapshot(value):
    if not isinstance(value,dict):die("migration snapshot is not an object")
    source=value.get("sourceRootPath");head=value.get("headObjectID")
    if not isinstance(source,str) or not source.startswith("/") or source=="/":die("invalid migration source root")
    if not isinstance(head,str) or len(head) not in (40,64) or any(item not in "0123456789abcdef" for item in head):die("invalid migration HEAD")
    symbolic=value.get("symbolicReference")
    if symbolic is not None and (not isinstance(symbolic,str) or not symbolic.startswith("refs/heads/") or len(symbolic.encode("utf-8"))>4096):die("invalid migration symbolic reference")
    roots=value.get("supplementalRoots",[]);nodes=value.get("supplementalManifest",[])
    if not isinstance(roots,list) or not isinstance(nodes,list) or len(roots)>MAX_FILES or len(nodes)>MAX_FILES:die("migration manifest exceeds bounds")
    if any(not isinstance(path,str) for path in roots):die("invalid supplemental root")
    roots=[valid(path) for path in roots]
    if len(set(roots))!=len(roots):die("duplicate supplemental roots")
    seen=set();path_bytes=sum(len(path.encode("utf-8")) for path in roots);content=0
    for node in nodes:
        if not isinstance(node,dict):die("invalid migration node")
        path=valid(node.get("relativePath"));kind=node.get("kind")
        if path in seen:die("duplicate migration path")
        seen.add(path);path_bytes+=len(path.encode("utf-8"))
        mode=node.get("permissions")
        if kind=="regular_file":
            if type(mode) is not int or mode not in range(0,512):die("invalid file mode")
            try:data=base64.b64decode(node.get("data",""),validate=True)
            except Exception:die("invalid migration file encoding")
            content+=len(data)
        elif kind=="directory":
            if node.get("data") is not None or type(mode) is not int or mode not in range(0,512):die("invalid directory metadata")
        elif kind=="absent":
            if node.get("data") is not None or mode is not None:die("invalid absent metadata")
        else:die("invalid migration node kind")
    if path_bytes>MAX_PATH_BYTES:die("migration paths exceed bounds")
    try:working=base64.b64decode(value.get("workingTreePatch",""),validate=True);staged=base64.b64decode(value.get("stagedPatch",""),validate=True)
    except Exception:die("invalid Git patch encoding")
    content+=len(working)+len(staged)
    if content>MAX_CONTENT:die("migration contents exceed bounds")
    return working,staged,nodes,roots
def comparable(value):
    nodes=sorted(value.get("supplementalManifest",[]),key=lambda item:item["relativePath"])
    return (value.get("headObjectID"),value.get("workingTreePatch",""),value.get("stagedPatch",""),nodes,sorted(value.get("supplementalRoots",[])))
def same_checkout_branch(value,baseline):
    return value.get("symbolicReference") == baseline.get("symbolicReference")
def uuid_token(value):
    if not isinstance(value,str) or len(value)!=36 or any(value[index]!="-" for index in (8,13,18,23)):die("invalid migration transaction ID")
    compact=value.replace("-","").lower()
    if len(compact)!=32 or any(item not in "0123456789abcdef" for item in compact):die("invalid migration transaction ID")
    return compact
def rename_noreplace(source_parent,source_name,destination_parent,destination_name):
    library=ctypes.CDLL(None,use_errno=True);source=os.fsencode(source_name);destination=os.fsencode(destination_name)
    if hasattr(library,"renameat2"):
        function=library.renameat2;flag=1
    elif hasattr(library,"renameatx_np"):
        function=library.renameatx_np;flag=4
    else:die("atomic no-replace install is unsupported on this host")
    function.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint];function.restype=ctypes.c_int
    if function(source_parent,source,destination_parent,destination,flag)!=0:
        code=ctypes.get_errno()
        if code in (errno.EEXIST,errno.ENOTEMPTY):die("supplemental destination collision")
        raise OSError(code,os.strerror(code))
def baseline_contract(desired,baseline):
    desired_working,desired_staged,_,desired_roots=validate_snapshot(desired)
    baseline_working,baseline_staged,_,baseline_roots=validate_snapshot(baseline)
    if baseline_working or baseline_staged or desired.get("headObjectID")!=baseline.get("headObjectID") or sorted(desired_roots)!=sorted(baseline_roots):die("remote migration baseline is incompatible")
    desired_nodes=node_map(desired);baseline_nodes=node_map(baseline)
    if any(node.get("kind")=="regular_file" for node in baseline_nodes.values()):die("remote migration baseline is not clean")
    for path in set(desired_nodes)|set(baseline_nodes):
        before=effective_node(baseline_nodes,path);after=effective_node(desired_nodes,path)
        if before["kind"]!="absent" and before!=after:die("remote migration would replace pre-existing supplemental state")
    return desired_working,desired_staged,desired_nodes,baseline_nodes,desired_roots
def create_directory(node):
    require_root_identity()
    parent,name=parent_and_name(node["relativePath"])
    try:
        os.mkdir(name,0o700,dir_fd=parent)
        descriptor=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
        try:os.fchmod(descriptor,0o700);os.fsync(descriptor)
        finally:os.close(descriptor)
        os.fsync(parent)
    finally:os.close(parent)
def create_file(node,token):
    require_root_identity()
    parent,name=parent_and_name(node["relativePath"]);temporary=None
    try:
        temporary=".lumachat-migrate-"+token+"-"+secrets.token_hex(8)
        descriptor=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=parent)
        try:
            data=base64.b64decode(node["data"],validate=True);offset=0
            while offset<len(data):
                written=os.write(descriptor,data[offset:])
                if written<=0:die("migration write made no progress")
                offset+=written
            os.fchmod(descriptor,node["permissions"]);os.fsync(descriptor)
        finally:os.close(descriptor)
        rename_noreplace(parent,temporary,parent,name);temporary=None;os.fsync(parent)
    finally:
        if temporary is not None:
            try:os.unlink(temporary,dir_fd=parent);os.fsync(parent)
            except OSError:pass
        os.close(parent)
def finalize_directory(node):
    descriptor=open_target(node["relativePath"])
    try:
        info=os.fstat(descriptor)
        if not stat.S_ISDIR(info.st_mode):die("migration directory changed before finalization",75)
        os.fchmod(descriptor,node["permissions"]);os.fsync(descriptor)
    finally:os.close(descriptor)
def install_supplemental(desired_nodes,baseline_nodes,token):
    directories=sorted([node for path,node in desired_nodes.items() if node["kind"]=="directory" and effective_node(baseline_nodes,path)["kind"]=="absent"],key=lambda node:(node["relativePath"].count("/"),node["relativePath"]))
    for node in directories:
        create_directory(node)
    files=sorted([node for path,node in desired_nodes.items() if node["kind"]=="regular_file" and effective_node(baseline_nodes,path)["kind"]=="absent"],key=lambda node:node["relativePath"])
    for node in files:create_file(node,token)
    for node in reversed(directories):finalize_directory(node)
def candidate_directories(nodes):
    values={()}
    for path in nodes:
        components=parts(path)
        for count in range(1,len(components)):values.add(tuple(components[:count]))
    return sorted(values,key=lambda item:(len(item),item),reverse=True)
def cleanup_transaction_temps(token,nodes):
    prefix=".lumachat-migrate-"+token+"-"
    for values in candidate_directories(nodes):
        try:descriptor=open_directory(list(values))
        except FileNotFoundError:continue
        try:
            changed=False
            for name in os.listdir(descriptor):
                if not name.startswith(prefix):continue
                info=os.stat(name,dir_fd=descriptor,follow_symlinks=False)
                if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid():die("transaction temporary node is unsafe",75)
                os.unlink(name,dir_fd=descriptor);changed=True
            if changed:os.fsync(descriptor)
        finally:os.close(descriptor)
def tracked_phase(current,desired,baseline):
    pair=(current.get("workingTreePatch",""),current.get("stagedPatch",""))
    clean=(baseline.get("workingTreePatch",""),baseline.get("stagedPatch",""))
    indexed=(baseline.get("workingTreePatch",""),desired.get("stagedPatch",""))
    full=(desired.get("workingTreePatch",""),desired.get("stagedPatch",""))
    if pair==clean:return "clean"
    if pair==full:return "full"
    if pair==indexed:return "indexed"
    return None
def supplemental_is_owned_partial(current,desired,baseline):
    if sorted(current.get("supplementalRoots",[]))!=sorted(desired.get("supplementalRoots",[])):return False
    current_nodes=node_map(current);desired_nodes=node_map(desired);baseline_nodes=node_map(baseline)
    for path in set(current_nodes)|set(desired_nodes)|set(baseline_nodes):
        value=effective_node(current_nodes,path)
        desired_value=effective_node(desired_nodes,path);baseline_value=effective_node(baseline_nodes,path)
        staging=desired_value.get("kind")=="directory" and baseline_value.get("kind")=="absent" and value.get("kind")=="directory" and value.get("permissions")==0o700 and value.get("data") is None
        if value!=desired_value and value!=baseline_value and not staging:return False
    return True
def remove_node(node):
    path=node["relativePath"]
    try:descriptor=open_target(path)
    except FileNotFoundError:return
    try:
        before=os.fstat(descriptor)
        if node["kind"]=="regular_file":
            if not stat.S_ISREG(before.st_mode) or stat.S_IMODE(before.st_mode)!=node["permissions"]:die("rollback file identity changed",75)
            chunks=[];remaining=MAX_CONTENT+1
            while remaining:
                chunk=os.read(descriptor,min(65536,remaining))
                if not chunk:break
                chunks.append(chunk);remaining-=len(chunk)
            after=os.fstat(descriptor)
            if signature(before)!=signature(after) or base64.b64encode(b"".join(chunks)).decode("ascii")!=node.get("data"):die("rollback file changed",75)
        elif node["kind"]=="directory":
            if not stat.S_ISDIR(before.st_mode) or stat.S_IMODE(before.st_mode) not in (node["permissions"],0o700) or os.listdir(descriptor):die("rollback directory changed",75)
        else:die("rollback node is invalid",75)
        expected=signature(before)
    finally:os.close(descriptor)
    parent,name=parent_and_name(path)
    try:
        current=os.stat(name,dir_fd=parent,follow_symlinks=False)
        if signature(current)!=expected:die("rollback node changed before removal",75)
        os.rmdir(name,dir_fd=parent) if node["kind"]=="directory" else os.unlink(name,dir_fd=parent)
        os.fsync(parent)
    finally:os.close(parent)
def rollback_transaction(desired,baseline,token):
    desired_working,desired_staged,desired_nodes,baseline_nodes,paths=baseline_contract(desired,baseline)
    cleanup_transaction_temps(token,set(desired_nodes)|set(baseline_nodes))
    current=capture(paths);was_clean=comparable(current)==comparable(baseline)
    phase=tracked_phase(current,desired,baseline)
    if current.get("headObjectID")!=desired.get("headObjectID") or not same_checkout_branch(current,baseline) or phase is None or not supplemental_is_owned_partial(current,desired,baseline):die("remote state changed outside the handoff transaction; rollback refused",75)
    if phase=="full" and desired_working:
        git(["apply","-R","--binary","--whitespace=nowarn","-"],desired_working,8*1024*1024)
        current=capture(paths);phase=tracked_phase(current,desired,baseline)
        if phase not in ("indexed","clean"):die("remote working rollback verification failed",75)
    if phase in ("indexed","full") and desired_staged:
        git(["apply","--cached","-R","--binary","--whitespace=nowarn","-"],desired_staged,8*1024*1024)
    current=capture(paths)
    if tracked_phase(current,desired,baseline)!="clean" or not supplemental_is_owned_partial(current,desired,baseline):die("remote tracked rollback verification failed",75)
    removable=[]
    for path,node in desired_nodes.items():
        if node["kind"]!="absent" and effective_node(baseline_nodes,path)["kind"]=="absent":removable.append(node)
    for node in sorted([item for item in removable if item["kind"]=="regular_file"],key=lambda item:(item["relativePath"].count("/"),item["relativePath"]),reverse=True):remove_node(node)
    for node in sorted([item for item in removable if item["kind"]=="directory"],key=lambda item:(item["relativePath"].count("/"),item["relativePath"]),reverse=True):remove_node(node)
    final=capture(paths)
    if comparable(final)!=comparable(baseline) or not same_checkout_branch(final,baseline):die("remote baseline restoration verification failed",75)
    return "already_clean" if was_clean else "rolled_back",final
raw=sys.stdin.buffer.read(MAX_TRANSACTION+1)
if len(raw)>MAX_TRANSACTION:die("migration request exceeds 8 MiB")
try:request=json.loads(raw.decode("utf-8"))
except Exception:die("migration request is invalid JSON")
if not isinstance(request,dict):die("migration request is not an object")
if op=="capture":
    result=capture(request.get("supplementalPaths",[]))
    sys.stdout.write(json.dumps(result,separators=(",",":"),sort_keys=True))
elif op in ("apply","rollback"):
    desired=request.get("desired");baseline=request.get("baseline");token=uuid_token(request.get("transactionID"))
    desired_working,desired_staged,desired_nodes,baseline_nodes,paths=baseline_contract(desired,baseline)
    if op=="rollback":
        status,final=rollback_transaction(desired,baseline,token)
        print(json.dumps({"status":status,"headObjectID":final["headObjectID"]},separators=(",",":")))
    else:
        current=capture(paths)
        if comparable(current)!=comparable(baseline) or not same_checkout_branch(current,baseline):die("remote destination no longer matches its captured baseline",75)
        try:
            if desired_staged:git(["apply","--cached","--binary","--whitespace=nowarn","-"],desired_staged,8*1024*1024)
            if desired_working:git(["apply","--binary","--whitespace=nowarn","-"],desired_working,8*1024*1024)
            install_supplemental(desired_nodes,baseline_nodes,token)
            final=capture(paths)
            if comparable(final)!=comparable(desired) or not same_checkout_branch(final,baseline):die("remote migration verification differs",75)
        except BaseException:
            try:rollback_transaction(desired,baseline,token)
            except BaseException as compensation:
                print("remote apply compensation is indeterminate: %s"%compensation,file=sys.stderr);sys.exit(75)
            raise
        print(json.dumps({"status":"applied","headObjectID":final["headObjectID"]},separators=(",",":")))
else:die("unsupported migration operation")
"""#
}
