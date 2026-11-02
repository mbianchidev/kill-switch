import Foundation
import TableQueryCore

public enum ActivityTableFields {
    public static let name = TableField<ActivityProcessSample>.text("name", title: "Process", aliases: ["command"]) { $0.process.name }
    public static let pid = TableField<ActivityProcessSample>.number("pid", title: "PID") { Decimal($0.process.identity.pid) }
    public static let user = TableField<ActivityProcessSample>.text("user", title: "User", aliases: ["owner"]) { $0.process.user }
    public static let cpu = TableField<ActivityProcessSample>.number("cpu", title: "CPU", aliases: ["CPU%", "% CPU"], unit: .percent) { $0.values.cpu }
    public static let memory = TableField<ActivityProcessSample>.number("memory", title: "Memory", aliases: ["mem"], unit: .bytes) { $0.values.memory }
    public static let received = TableField<ActivityProcessSample>.number("received", title: "Received/s", aliases: ["download"], unit: .bytesPerSecond) { $0.values.received }
    public static let sent = TableField<ActivityProcessSample>.number("sent", title: "Sent/s", aliases: ["upload"], unit: .bytesPerSecond) { $0.values.sent }
    public static let read = TableField<ActivityProcessSample>.number("read", title: "Read/s", aliases: ["diskRead"], unit: .bytesPerSecond) { $0.values.diskRead }
    public static let written = TableField<ActivityProcessSample>.number("written", title: "Written/s", aliases: ["write", "diskWritten"], unit: .bytesPerSecond) { $0.values.diskWritten }
    public static let columns = [name, pid, cpu, memory, received, sent, read, written]
    public static let all = columns + [user]
}

public enum HistoricalProcessFields {
    public static let name = TableField<ActivityProcessDescriptor>.text("name", title: "Process", aliases: ["command"]) { $0.name }
    public static let pid = TableField<ActivityProcessDescriptor>.number("pid", title: "PID") { Decimal($0.identity.pid) }
    public static let user = TableField<ActivityProcessDescriptor>.text("user", title: "User", aliases: ["owner"]) { $0.user }
    public static let all = [name, pid, user]
}

public enum OpenFileTableFields {
    public static let path = TableField<OpenFileRecord>.text("path", title: "Path", aliases: ["file"]) { $0.path }
    public static let process = TableField<OpenFileRecord>.text("process", title: "Process", aliases: ["name", "command"]) { $0.process }
    public static let pid = TableField<OpenFileRecord>.number("pid", title: "PID") { Decimal($0.pid) }
    public static let user = TableField<OpenFileRecord>.text("user", title: "User", aliases: ["owner"]) { $0.user }
    public static let descriptor = TableField<OpenFileRecord>.text("descriptor", title: "FD") { $0.descriptor }
    public static let access = TableField<OpenFileRecord>.text("access", title: "Access", values: ["Read", "Write", "Read/write", "Unknown"]) { $0.accessDescription }
    public static let lock = TableField<OpenFileRecord>.text("lock", title: "Lock", values: ["Read", "Write", "Exclusive", "Unknown lock"]) {
        $0.hasLock ? $0.lockDescription : nil
    }
    public static let kind = TableField<OpenFileRecord>.text("type", title: "Type", aliases: ["kind"], values: ["REG", "DIR", "unix"]) { $0.kind }
    public static let size = TableField<OpenFileRecord>.number("size", title: "Size", unit: .bytes) { $0.size.map(Decimal.init) }
    public static let locked = TableField<OpenFileRecord>.boolean("locked", title: "Reported lock") { $0.hasLock }
    public static let columns = [path, process, pid, user, descriptor, access, lock, kind, size]
    public static let all = columns + [locked]
}

public enum ConnectionTableFields {
    public static let process = TableField<NetworkConnectionRecord>.text("process", title: "Process", aliases: ["name", "command"]) { $0.process }
    public static let pid = TableField<NetworkConnectionRecord>.number("pid", title: "PID") { Decimal($0.pid) }
    public static let user = TableField<NetworkConnectionRecord>.text("user", title: "User", aliases: ["owner"]) { $0.user }
    public static let protocolName = TableField<NetworkConnectionRecord>.text("protocol", title: "Protocol", values: ["TCP", "UDP", "Unix"]) { $0.protocolName }
    public static let protocolDisplay = TableField<NetworkConnectionRecord>.text("protocolFamily", title: "Protocol / family") { $0.protocolDescription }
    public static let local = TableField<NetworkConnectionRecord>.text("local", title: "Local endpoint") { $0.local }
    public static let remote = TableField<NetworkConnectionRecord>.text("remote", title: "Remote endpoint") { $0.remote }
    public static let state = TableField<NetworkConnectionRecord>.text("state", title: "State", values: ["LISTEN", "ESTABLISHED", "BOUND", "CONNECTED", "CLOSED"]) { $0.state }
    public static let localPort = TableField<NetworkConnectionRecord>.number("port", title: "Local port", aliases: ["localPort"]) { $0.localPort.map(Decimal.init) }
    public static let remotePort = TableField<NetworkConnectionRecord>.number("remotePort", title: "Remote port") { $0.remotePort.map(Decimal.init) }
    public static let family = TableField<NetworkConnectionRecord>.text("family", title: "Address family", values: ["IPv4", "IPv6", "unix"]) { $0.family }
    public static let columns = [process, pid, user, protocolDisplay, local, remote, state]
    public static let all = columns + [protocolName, localPort, remotePort, family]
}
