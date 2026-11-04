// Windows 服务与控制台守护入口，负责配置解析、进程接管和生命周期监控。
module app;

version(Windows)
{
}
else
{
    static assert(false, "本程序仅支持 Windows。");
}

// Windows API、运行时线程与宽字符支持。
import core.stdc.wchar_: wcslen;
import core.sys.windows.tlhelp32;
import core.sys.windows.windows;
import core.sys.windows.winsvc;
import core.thread: thread_attachThis, thread_detachThis;

// 配置、路径、日志与编码支持。
import std.algorithm: canFind;
import std.conv: to;
import std.datetime: Clock, SysTime;
import std.format: format;
import std.file: exists, isFile, readText;
import std.path: baseName, buildPath, dirName, isAbsolute, setExtension, stripExtension;
import std.stdio: File, stderr, stdout;
import std.string: replace, splitLines, strip;
import std.uni: toLower;
import std.utf: toUTF16, toUTF16z, toUTF8;

pragma(lib, "advapi32.lib");

// 服务入口与系统控制回调运行在不同线程；路径只在进入服务调度前初始化。
private __gshared SERVICE_STATUS_HANDLE statusHandle;
private __gshared HANDLE stopEvent;

private __gshared string configPath;
private __gshared string logPath;
private __gshared string serviceName;

private struct ManagedProgram
{
    string path;
    HANDLE process;
    RetryBudget budget;
}

// 每个程序独立计数；首次允许启动，后续恢复受上限约束。
struct RetryBudget
{
    uint maxRetries = 5;
    uint retries;
    bool initialAttempt = true;
    bool abandoned;

    // 消耗一次启动机会，耗尽后保持放弃状态。
    bool beginAttempt()
    {
        if(abandoned) return false;
        if(initialAttempt)
        {
            initialAttempt = false;
            return true;
        }
        if(retries == maxRetries)
        {
            abandoned = true;
            return false;
        }
        ++retries;
        return true;
    }

    // 只有后续检查确认进程仍存活，才恢复完整重试预算。
    void observedAlive()
    {
        retries = 0;
    }
}

// INI 中的服务设置与规范化后的程序路径。
struct ServiceConfig
{
    uint maxRetries = 5;
    string[] paths;
}

// 查询完整进程映像路径；补充当前 D Windows 绑定缺失的系统接口。
private extern (Windows) BOOL QueryFullProcessImageNameW(HANDLE process, DWORD flags, LPWSTR path, DWORD* size) nothrow;

// 根据完整映像路径接管既有进程，不依赖可能被复用的已保存 PID。
private bool adoptProgram(ref ManagedProgram program)
{
    auto snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if(snapshot == INVALID_HANDLE_VALUE)
    {
        throw windowsError("枚举进程失败");
    }
    scope(exit)
    {
        CloseHandle(snapshot);
    }
    PROCESSENTRY32W entry;
    entry.dwSize = cast(DWORD)entry.sizeof;
    auto available = Process32FirstW(snapshot, &entry);
    auto targetNameKey = pathKey(program.path.baseName);
    auto targetPathKey = pathKey(program.path);
    // 仅在发现同名候选时分配缓冲，并在本次枚举中复用。
    wchar[] buffer;

    while(available)
    {
        auto imageName = toUTF8(entry.szExeFile[0 .. wcslen(entry.szExeFile.ptr)]);
        if(pathKey(imageName) == targetNameKey)
        {
            // PROCESS_QUERY_LIMITED_INFORMATION 是查询映像及退出状态所需的最小权限。
            enum processQueryLimitedInformation = 0x1000;
            auto process = OpenProcess(SYNCHRONIZE | processQueryLimitedInformation, FALSE, entry.th32ProcessID);
            if(process is null)
            {
                auto error = GetLastError();
                if(error != ERROR_INVALID_PARAMETER)
                {
                    throw windowsError("无法核对同名进程，为避免重复启动暂不启动：" ~ program.path, error);
                }
            }
            else
            {
                bool adopted;
                scope(exit)
                {
                    if(!adopted)
                    {
                        CloseHandle(process);
                    }
                }
                if(buffer.length == 0)
                {
                    buffer = new wchar[32768];
                }
                DWORD size = cast(DWORD)buffer.length;
                if(!QueryFullProcessImageNameW(process, 0, buffer.ptr, &size))
                {
                    if(WaitForSingleObject(process, 0) != WAIT_OBJECT_0)
                    {
                        throw windowsError("读取已有进程路径失败：" ~ program.path);
                    }
                }
                else if(pathKey(toUTF8(buffer[0 .. size])) == targetPathKey && WaitForSingleObject(process, 0) == WAIT_TIMEOUT)
                {
                    program.process = process;
                    adopted = true;
                    logMessage("接管已有程序：" ~ program.path ~ "，PID=" ~ entry.th32ProcessID.to!string);
                    return true;
                }
            }
        }
        available = Process32NextW(snapshot, &entry);
    }

    if(GetLastError() != ERROR_NO_MORE_FILES)
    {
        throw windowsError("枚举进程失败");
    }
    return false;
}

// 检查进程句柄；已退出的程序在同一次轮询内重新启动。
private void checkProgram(ref ManagedProgram program)
{
    if(program.budget.abandoned) return;
    if(program.process !is null)
    {
        auto result = WaitForSingleObject(program.process, 0);
        if(result == WAIT_TIMEOUT)
        {
            program.budget.observedAlive();
            return;
        }
        if(result == WAIT_FAILED)
        {
            throw windowsError("检查进程失败：" ~ program.path);
        }
        DWORD exitCode;
        if(!GetExitCodeProcess(program.process, &exitCode))
        {
            throw windowsError("读取进程退出码失败：" ~ program.path);
        }
        logMessage("程序已退出：" ~ program.path ~ "，退出码=" ~ exitCode.to!string ~ "，准备重新启动");
        closeProgram(program);
    }
    if(!program.budget.beginAttempt())
    {
        logMessage("放弃重启：" ~ program.path ~ "，重试上限=" ~ program.budget.maxRetries.to!string);
        return;
    }
    startProgram(program);
}

// 只释放监控句柄，不终止原程序。
private void closeProgram(ref ManagedProgram program)
{
    if(program.process !is null)
    {
        CloseHandle(program.process);
        program.process = null;
    }
}

// 支持控制台调试模式的 Ctrl+C 和窗口关闭事件。
private extern (Windows) BOOL consoleControl(DWORD control) nothrow
{
    if(control == CTRL_C_EVENT || control == CTRL_BREAK_EVENT || control == CTRL_CLOSE_EVENT)
    {
        SetEvent(stopEvent);
        return TRUE;
    }
    return FALSE;
}

// 获取当前可执行文件路径，不依赖服务管理器的工作目录。
private string executablePath()
{
    wchar[] buffer = new wchar[32768];
    auto length = GetModuleFileNameW(null, buffer.ptr, cast(DWORD)buffer.length);
    if(length == 0 || length >= buffer.length)
    {
        throw windowsError("获取可执行文件路径失败");
    }
    return toUTF8(buffer[0 .. length]);
}

// 统一日志时间戳为固定三位毫秒，确保同一列起始位置一致。
string formatLogTimestamp(SysTime time)
{
    return format!"%04d-%02d-%02dT%02d:%02d:%02d.%03d"(time.year, time.month, time.day,
        time.hour, time.minute, time.second, time.fracSecs.total!"msecs");
}

// 安装为自动启动服务；路径加引号以支持含空格的安装目录。
private void installService(string executable)
{
    if(!exists(configPath) || !isFile(configPath))
    {
        throw new Exception("请先创建配置文件：" ~ configPath);
    }
    parseConfig(readText(configPath), configPath, executable);
    auto manager = OpenSCManagerW(null, null, SC_MANAGER_CREATE_SERVICE);
    if(manager is null)
    {
        throw windowsError("打开服务管理器失败，请使用管理员权限");
    }
    scope(exit)
    {
        CloseServiceHandle(manager);
    }
    auto service = CreateServiceW(manager, serviceName.toUTF16z, serviceName.toUTF16z, SERVICE_QUERY_STATUS, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START,
        SERVICE_ERROR_NORMAL, ("\"" ~ executable ~ "\"").toUTF16z, null, null, null, null, null);
    if(service is null)
    {
        throw windowsError("安装服务失败");
    }
    CloseServiceHandle(service);
    writeTerminal("服务已安装为自动启动：" ~ serviceName ~ "；请使用 sc.exe start " ~ serviceName ~ " 启动。");
}

// 使用系统追加权限一次写入完整 UTF-8 行，允许守护和测试进程共享日志。
void appendLogLine(string path, string line)
{
    auto file = CreateFileW(path.toUTF16z, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if(file == INVALID_HANDLE_VALUE)
    {
        throw windowsError("打开日志失败：" ~ path);
    }
    scope(exit) CloseHandle(file);
    auto text = line ~ "\r\n";
    DWORD written;
    if(!WriteFile(file, text.ptr, cast(DWORD)text.length, &written, null) || written != text.length)
    {
        throw windowsError("写入日志失败：" ~ path);
    }
}

// 追加 UTF-8 日志；单次日志写入失败不打断其他程序的守护。
private void logMessage(string message)
{
    try
    {
        appendLogLine(logPath, formatLogTimestamp(Clock.currTime()) ~ " [守护] " ~ message);
    }
    catch(Exception error)
    {
        try
        {
            writeTerminal("日志写入失败：" ~ error.msg ~ "；" ~ message, true);
        }
        catch(Exception)
        {
        }
    }
}

// 默认由服务管理器启动，也可显式安装、卸载或进入控制台调试模式。
int main(string[] arguments)
{
    try
    {
        auto executable = executablePath();
        serviceName = executable.baseName.stripExtension;
        configPath = executable.setExtension("ini");
        logPath = executable.setExtension("log");
        if(arguments.length == 2 && arguments[1] == "--install")
        {
            installService(executable);
            return 0;
        }
        if(arguments.length == 2 && arguments[1] == "--uninstall")
        {
            uninstallService();
            return 0;
        }
        bool console = arguments.length == 2 && arguments[1] == "--console";
        if(arguments.length > 1 && !console)
        {
            writeTerminal("用法：" ~ serviceName ~ ".exe [--install | --uninstall | --console]");
            return arguments.length == 2 && arguments[1] == "--help" ? 0 : 1;
        }
        // 服务模式和调试模式共享互斥锁，防止同名守护实例并发拉起重复进程。
        auto mutex = CreateMutexW(null, FALSE, ("Global\\dservice-" ~ serviceName).toUTF16z);
        if(mutex is null)
        {
            throw windowsError("创建守护互斥锁失败");
        }
        auto mutexError = GetLastError();
        scope(exit)
        {
            CloseHandle(mutex);
        }
        if(mutexError == ERROR_ALREADY_EXISTS)
        {
            throw new Exception("同名守护程序已运行：" ~ serviceName);
        }
        stopEvent = CreateEventW(null, TRUE, FALSE, null);
        if(stopEvent is null)
        {
            throw windowsError("创建停止事件失败");
        }
        scope(exit)
        {
            CloseHandle(stopEvent);
        }
        if(console)
        {
            if(!SetConsoleCtrlHandler(&consoleControl, TRUE))
            {
                throw windowsError("注册控制台回调失败");
            }
            scope(exit)
            {
                SetConsoleCtrlHandler(&consoleControl, FALSE);
            }
            writeTerminal("控制台守护模式，按 Ctrl+C 停止。日志：" ~ logPath);
            supervise(false);
        }
        else
        {
            SERVICE_TABLE_ENTRYW[2] table;
            table[0].lpServiceName = cast(LPWSTR)serviceName.toUTF16z;
            table[0].lpServiceProc = &serviceMain;
            if(!StartServiceCtrlDispatcherW(table.ptr))
            {
                throw windowsError("连接服务管理器失败；调试请使用 --console，安装请使用 --install");
            }
        }
        return 0;
    }
    catch(Exception error)
    {
        if(logPath.length)
        {
            logMessage(error.msg);
        }
        writeTerminal(error.msg, true);
        return 1;
    }
}

// 解析 UTF-8 INI；相对程序路径固定以配置文件所在目录为基准。
ServiceConfig parseConfig(string text, string iniPath, string executable = "")
{
    if(text.length >= 3 && text[0 .. 3] == "\xEF\xBB\xBF") text = text[3 .. $];
    ServiceConfig config;
    string section;
    bool retriesSpecified;
    string[uint] numberedPaths;
    auto directory = normalizePath(iniPath).dirName;
    auto executableKey = executable.length ? pathKey(normalizePath(executable)) : "";
    foreach(index, rawLine; text.splitLines())
    {
        auto line = rawLine.strip;
        if(line.length == 0 || line[0] == ';' || line[0] == '#') continue;
        auto invalid = "配置第 " ~ (index + 1).to!string ~ " 行无效：";
        if(line[0] == '[' && line[$ - 1] == ']')
        {
            section = line[1 .. $ - 1].strip;
            if(section != "service" && section != "programs")
                throw new Exception(invalid ~ "未知节 " ~ section);
            continue;
        }
        import std.string: indexOf;
        auto separator = line.indexOf('=');
        if(separator <= 0) throw new Exception(invalid ~ "需要 key=value");
        auto key = line[0 .. separator].strip;
        auto value = line[separator + 1 .. $].strip;
        if(section == "service")
        {
            if(key != "maxRetries" || retriesSpecified)
                throw new Exception(invalid ~ "未知或重复的服务设置");
            if(value.length == 0) throw new Exception(invalid ~ "maxRetries 必须为非负整数");
            uint count;
            foreach(character; value)
            {
                if(character < '0' || character > '9' || count > (uint.max - (character - '0')) / 10)
                    throw new Exception(invalid ~ "maxRetries 必须为 0 到 " ~ uint.max.to!string ~ " 的整数");
                count = count * 10 + (character - '0');
            }
            config.maxRetries = count;
            retriesSpecified = true;
        }
        else if(section == "programs")
        {
            if(key.length <= 3 || key[0 .. 3] != "app" || key[3] < '1' || key[3] > '9')
                throw new Exception(invalid ~ "程序名称必须为 app1、app2 等连续编号");
            uint number;
            foreach(character; key[3 .. $])
            {
                if(character < '0' || character > '9' || number > (uint.max - (character - '0')) / 10)
                    throw new Exception(invalid ~ "程序编号无效");
                number = number * 10 + (character - '0');
            }
            if(number in numberedPaths) throw new Exception(invalid ~ "程序编号重复");
            if(value.length >= 2 && value[0] == '"' && value[$ - 1] == '"') value = value[1 .. $ - 1];
            if(value.length == 0 || value.canFind('\0') || value.canFind('"'))
                throw new Exception(invalid ~ "程序路径无效");
            // 拒绝依赖当前驱动器的路径，避免与 INI 目录基准相冲突。
            if(!isAbsolute(value) && (value.canFind(':') || value[0] == '\\' || value[0] == '/'))
                throw new Exception(invalid ~ "请使用完整绝对路径或相对路径");
            auto path = normalizePath(isAbsolute(value) ? value : buildPath(directory, value));
            if(pathKey(path) == executableKey) throw new Exception("配置不能包含守护程序自身");
            numberedPaths[number] = path;
        }
        else throw new Exception(invalid ~ "设置必须位于 [service] 或 [programs] 中");
    }
    // 按数值编号排序并验证连续性，然后按规范化路径去重。
    foreach(index; 0 .. numberedPaths.length)
    {
        auto entry = (cast(uint)index + 1) in numberedPaths;
        if(entry is null) throw new Exception("程序编号必须从 app1 开始连续递增");
        bool duplicate;
        foreach(existing; config.paths) duplicate |= pathKey(existing) == pathKey(*entry);
        if(!duplicate) config.paths ~= *entry;
    }
    if(config.paths.length == 0) throw new Exception("配置文件中没有程序路径");
    return config;
}

// 使用 Windows 路径规则消除相对段并得到完整路径。
private string normalizePath(string path)
{
    wchar[] buffer = new wchar[32768];
    auto length = GetFullPathNameW(path.toUTF16z, cast(DWORD)buffer.length, buffer.ptr, null);
    if(length == 0 || length >= buffer.length) throw windowsError("配置路径规范化失败");
    return toUTF8(buffer[0 .. length]);
}

// 统一 Windows 路径分隔符和大小写以匹配配置与进程映像。
private string pathKey(string path)
{
    return path.replace("/", "\\").toLower;
}

// 上报服务状态，启动阶段不接受停止控制。
private void reportStatus(DWORD state, DWORD error = NO_ERROR)
{
    SERVICE_STATUS status;
    status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    status.dwCurrentState = state;
    status.dwWin32ExitCode = error;
    status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
    if(state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING)
    {
        status.dwCheckPoint = 1;
        status.dwWaitHint = 10000;
    }
    if(!SetServiceStatus(statusHandle, &status))
    {
        logMessage("上报服务状态失败，Windows 错误码：" ~ GetLastError().to!string);
    }
}

// 服务控制回调仅发送事件，由守护线程统一清理进程和上报状态。
private extern (Windows) void serviceControl(DWORD control) nothrow
{
    if(control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN)
    {
        SetEvent(stopEvent);
    }
}

// Windows 服务入口，不让 D 异常跨越系统回调边界。
private extern (Windows) void serviceMain(DWORD argumentCount, LPWSTR* arguments) nothrow
{
    try
    {
        // 服务线程由 Windows 创建，先附加到 D 运行时以正确参与垃圾回收。
        thread_attachThis();
        scope(exit)
        {
            thread_detachThis();
        }
        statusHandle = RegisterServiceCtrlHandlerW(serviceName.toUTF16z, &serviceControl);
        if(statusHandle is null)
        {
            logMessage("注册服务控制回调失败，Windows 错误码：" ~ GetLastError().to!string);
            return;
        }
        reportStatus(SERVICE_START_PENDING);

        try
        {
            supervise(true);
            reportStatus(SERVICE_STOPPED);
        }
        catch(Exception error)
        {
            logMessage("服务运行失败：" ~ error.msg);
            reportStatus(SERVICE_STOPPED, ERROR_EXCEPTION_IN_SERVICE);
        }
    }
    catch(Throwable)
    {
    }
}

// 创建独立后台程序，关闭守护程序不会终止该程序。
private void startProgram(ref ManagedProgram program)
{
    if(adoptProgram(program))
    {
        return;
    }
    STARTUPINFOW startup;
    startup.cb = cast(DWORD)startup.sizeof;
    PROCESS_INFORMATION processInfo;
    // CreateProcessW 可能修改命令行，必须使用独立的可写缓冲区。
    auto mutableCommand = ("\"" ~ program.path ~ "\"\0").toUTF16.dup;
    if(!CreateProcessW(program.path.toUTF16z, mutableCommand.ptr, null, null, FALSE, CREATE_NO_WINDOW, null, program.path.dirName.toUTF16z, &startup, &processInfo))
    {
        throw windowsError("创建进程失败：" ~ program.path);
    }
    scope(exit)
    {
        CloseHandle(processInfo.hThread);
    }
    program.process = processInfo.hProcess;
    logMessage("启动成功：" ~ program.path ~ "，PID=" ~ processInfo.dwProcessId.to!string);
}

// 读取配置并持续守护；停止事件可立即打断三秒等待。
private void supervise(bool asService)
{
    // 启动时先验证日志可写，避免服务在完全无日志的状态下运行。
    auto logFile = File(logPath, "a");
    logFile.close();
    if(!exists(configPath) || !isFile(configPath)) throw new Exception("请先创建配置文件：" ~ configPath);
    auto config = parseConfig(readText(configPath), configPath, executablePath());
    ManagedProgram[] programs;

    foreach(path; config.paths)
    {
        programs ~= ManagedProgram(path, null, RetryBudget(config.maxRetries));
    }

    scope(exit)
    {
        if(asService)
        {
            reportStatus(SERVICE_STOP_PENDING);
        }

        foreach(ref program; programs)
        {
            if(program.process !is null)
            {
                logMessage("停止监控，保留程序运行：" ~ program.path);
            }
            closeProgram(program);
        }

        logMessage("守护已停止");
    }
    logMessage("守护启动，配置：" ~ configPath ~ "，程序数量：" ~ programs.length.to!string);
    if(asService)
    {
        reportStatus(SERVICE_RUNNING);
    }

    while(WaitForSingleObject(stopEvent, 0) == WAIT_TIMEOUT)
    {
        foreach(ref program; programs)
        {
            if(WaitForSingleObject(stopEvent, 0) != WAIT_TIMEOUT)
            {
                break;
            }

            try
            {
                checkProgram(program);
            }
            catch(Exception error)
            {
                logMessage(error.msg ~ "；3 秒后检查重试预算");
            }
        }

        auto result = WaitForSingleObject(stopEvent, 3000);
        if(result == WAIT_OBJECT_0)
        {
            break;
        }
        if(result == WAIT_FAILED)
        {
            throw windowsError("等待停止事件失败");
        }
    }
}

// 仅卸载已停止的服务，避免卸载时意外中断正在运行的程序。
private void uninstallService()
{
    auto manager = OpenSCManagerW(null, null, SC_MANAGER_CONNECT);
    if(manager is null)
    {
        throw windowsError("打开服务管理器失败，请使用管理员权限");
    }
    scope(exit)
    {
        CloseServiceHandle(manager);
    }
    auto service = OpenServiceW(manager, serviceName.toUTF16z, DELETE | SERVICE_QUERY_STATUS);
    if(service is null)
    {
        throw windowsError("打开服务失败");
    }
    scope(exit)
    {
        CloseServiceHandle(service);
    }
    SERVICE_STATUS status;
    if(!QueryServiceStatus(service, &status))
    {
        throw windowsError("查询服务状态失败");
    }
    if(status.dwCurrentState != SERVICE_STOPPED)
    {
        throw new Exception("请先执行 sc.exe stop " ~ serviceName ~ "，待服务停止后再卸载");
    }
    if(!DeleteService(service))
    {
        throw windowsError("卸载服务失败");
    }
    writeTerminal("服务已卸载：" ~ serviceName);
}

// 将 Windows API 错误转换为含错误码的异常。
private Exception windowsError(string operation, DWORD error = GetLastError())
{
    return new Exception(operation ~ "，Windows 错误码：" ~ error.to!string);
}

// 控制台使用 Unicode 接口，重定向时保持 UTF-8，不改变共享控制台的代码页。
void writeTerminal(string message, bool errorOutput = false)
{
    auto handle = GetStdHandle(errorOutput ? STD_ERROR_HANDLE : STD_OUTPUT_HANDLE);
    DWORD mode;
    if(GetConsoleMode(handle, &mode))
    {
        auto text = (message ~ "\r\n").toUTF16;
        while(text.length > 0)
        {
            DWORD written;
            auto length = cast(DWORD)(text.length > 8192 ? 8192 : text.length);
            if(!WriteConsoleW(handle, text.ptr, length, &written, null) || written == 0)
            {
                throw windowsError("写入控制台失败");
            }
            text = text[written .. $];
        }
        return;
    }
    auto output = errorOutput ? stderr : stdout;
    output.writeln(message);
}
