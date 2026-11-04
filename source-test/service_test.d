// 使用 D unittest 验证配置解析及两个 demo 的启动、重启、保留、接管和清理。
module service_test;

version(unittest):
import app: appendLogLine, formatLogTimestamp, parseConfig, RetryBudget, writeTerminal;
import core.sys.windows.windows;
import core.stdc.wchar_: wcslen;
import core.sys.windows.tlhelp32;
import std.algorithm: canFind;
import std.conv: to;
import std.datetime: Clock;
import std.exception: assertThrown;
import std.file: copy, exists, readText, thisExePath, write;
import std.path: baseName, buildPath, dirName;
import std.process: execute;
import std.string: indexOf, splitLines;
import std.uni: toLower;
import std.utf: toUTF16, toUTF16z, toUTF8;

// 两个固定产物同时用于手工演示和自动测试，运行时不可互相占用。
private enum shortDemoName = "dservice-demo-exit.exe";

// 两个持续运行的演示程序名称。
private immutable string[] demoNames = ["dservice-demo-a.exe", "dservice-demo-b.exe"];

// 在任何 unittest 执行之前识别 demo，防止复制后的程序递归运行测试。
shared static this()
{
    if(thisExePath.baseName.toLower == shortDemoName) ExitProcess(0);
    if(demoNames.canFind(thisExePath.baseName.toLower))
    {
        Sleep(INFINITE);
    }
}

// 查询完整映像路径，避免仅凭旧 PID 清理无关进程。
private extern(Windows) BOOL QueryFullProcessImageNameW(HANDLE process, DWORD flags, LPWSTR path, DWORD* size) nothrow;

// 启动测试守护，返回用于等待和清理的进程句柄。
private HANDLE launch(string executable, string argument)
{
    STARTUPINFOW startup;
    startup.cb = cast(DWORD)startup.sizeof;
    PROCESS_INFORMATION info;
    auto command = ("\"" ~ executable ~ "\" " ~ argument ~ "\0").toUTF16.dup;
    assert(CreateProcessW(executable.toUTF16z, command.ptr, null, null, FALSE, CREATE_NO_WINDOW, null, null, &startup, &info), "启动测试进程失败");
    CloseHandle(info.hThread);
    return info.hProcess;
}

// 核对当前句柄的完整路径，仅允许操作指定的测试产物。
private HANDLE openWorker(DWORD pid, string path)
{
    enum processQueryLimitedInformation = 0x1000;
    auto process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE | processQueryLimitedInformation, FALSE, pid);
    if(process is null)
    {
        return null;
    }
    wchar[] buffer = new wchar[32768];
    DWORD size = cast(DWORD)buffer.length;
    if(QueryFullProcessImageNameW(process, 0, buffer.ptr, &size)
        && toUTF8(buffer[0 .. size]).toLower == path.toLower)
    {
        return process;
    }
    CloseHandle(process);
    return null;
}

// 终止并等待已持有句柄的测试进程，断言退出后再释放句柄。
private void terminate(ref HANDLE process)
{
    if(process is null)
    {
        return;
    }
    if(WaitForSingleObject(process, 0) != WAIT_OBJECT_0)
    {
        assert(TerminateProcess(process, 0), "终止测试进程失败");
    }
    assert(WaitForSingleObject(process, 5000) == WAIT_OBJECT_0, "测试进程未退出");
    CloseHandle(process);
    process = null;
}

// 枚举并清理测试独占路径下的残留实例，不依赖日志中的历史 PID。
private void cleanupWorkers(string[] paths)
{
    auto snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    assert(snapshot != INVALID_HANDLE_VALUE, "枚举测试进程失败");
    scope(exit) CloseHandle(snapshot);
    PROCESSENTRY32W entry;
    entry.dwSize = cast(DWORD)entry.sizeof;
    auto available = Process32FirstW(snapshot, &entry);
    while(available)
    {
        // 先按文件名筛选，避免为无关系统进程分配完整路径缓冲区。
        auto imageName = toUTF8(entry.szExeFile[0 .. wcslen(entry.szExeFile.ptr)]).toLower;
        foreach(path; paths)
        {
            if(imageName != path.baseName.toLower)
            {
                continue;
            }
            auto process = openWorker(entry.th32ProcessID, path);
            terminate(process);
        }
        available = Process32NextW(snapshot, &entry);
    }
    assert(GetLastError() == ERROR_NO_MORE_FILES, "枚举测试进程未完成");
}

// 统一输出固定宽度时间戳和两字日志头，可同时追加独立事件日志。
private void recordStep(string eventPath, string message, string heading = "测试")
{
    auto line = formatLogTimestamp(Clock.currTime()) ~ " [" ~ heading ~ "] " ~ message;
    if(eventPath.length > 0)
    {
        appendLogLine(eventPath, line);
    }
    writeTerminal(line);
}

// 读取指定事件对应的 PID 列表。
private DWORD[] loggedPids(string text, string prefix)
{
    DWORD[] result;
    foreach(line; text.splitLines)
    {
        if(!line.canFind(prefix)) continue;
        auto position = line.indexOf("PID=");
        if(position >= 0) result ~= line[position + 4 .. $].to!DWORD;
    }
    return result;
}

// 日志尚未创建时返回空字符串。
private string readLog(string path)
{
    return exists(path) ? readText(path) : "";
}

// 等待条件满足，最长十五秒。
private void waitUntil(bool delegate() condition, string message)
{
    foreach(attempt; 0 .. 150)
    {
        if(condition()) return;
        Sleep(100);
    }
    assert(false, message);
}

// 生成并独占测试 demo；文件被占用时停止测试，不操作已有实例。
private void generateDemos()
{
    foreach(name; demoNames ~ [shortDemoName])
    {
        auto destination = buildPath(thisExePath.dirName, name);
        if(!CopyFileW(thisExePath.toUTF16z, destination.toUTF16z, FALSE))
        {
            auto error = GetLastError();
            // CopyFileW 对已映射的 exe 可能报告拒绝访问；用写入句柄确认是否确为共享冲突，不写文件。
            if(error == ERROR_ACCESS_DENIED)
            {
                auto probe = CreateFileW(destination.toUTF16z, GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_EXISTING, 0, null);
                if(probe != INVALID_HANDLE_VALUE)
                {
                    CloseHandle(probe);
                }
                else if(GetLastError() == ERROR_SHARING_VIOLATION)
                {
                    error = ERROR_SHARING_VIOLATION;
                }
            }
            if(error != ERROR_SHARING_VIOLATION)
            {
                throw new Exception("生成 demo 失败：" ~ destination ~ "，Windows 错误码：" ~ error.to!string);
            }
            throw new Exception("测试产物正在使用：" ~ destination ~
                "；请先停止手工守护及两个 demo，再执行 dub test。未终止已有实例。");
        }
        else
        {
            recordStep("", "测试程序：" ~ destination, "生成");
        }
    }
}

unittest
{
    // 禁止并行测试争用同一组 demo；手工守护也必须先停止。
    auto testMutex = CreateMutexW(null, FALSE, "Global\\dservice-demo-unittest"w.ptr);
    assert(testMutex !is null, "创建测试互斥锁失败");
    auto mutexError = GetLastError();
    scope(exit) CloseHandle(testMutex);
    assert(mutexError != ERROR_ALREADY_EXISTS, "已有测试正在使用 .dub 中的 demo");
    auto guardMutex = CreateMutexW(null, FALSE, "Global\\dservice-dservice"w.ptr);
    assert(guardMutex !is null, "无法确认手工守护是否停止");
    auto guardMutexError = GetLastError();
    scope(exit) CloseHandle(guardMutex);
    assert(guardMutexError != ERROR_ALREADY_EXISTS, "请先停止 dservice 手工守护或服务，再运行测试");
    generateDemos();
    import std.datetime: DateTime, SysTime;
    import core.time: msecs, usecs;
    auto timestampBase = SysTime(DateTime(2026, 11, 4, 11, 13, 53));
    assert(formatLogTimestamp(timestampBase) == "2026-11-04T11:13:53.000");
    assert(formatLogTimestamp(timestampBase + msecs(7)) == "2026-11-04T11:13:53.007");
    assert(formatLogTimestamp(timestampBase + usecs(231657)) == "2026-11-04T11:13:53.231");
    assert(formatLogTimestamp(timestampBase + msecs(999)) == "2026-11-04T11:13:53.999");
    auto suffix = GetCurrentProcessId().to!string ~ "-" ~ GetTickCount().to!string;
    auto directory = thisExePath.dirName;
    // 每次使用新的日志和配置，保留历史记录且不覆盖手工守护配置。
    auto guardName = "守护 test-" ~ suffix;
    auto executable = buildPath(directory, guardName ~ ".exe");
    auto logPath = buildPath(directory, guardName ~ ".log");
    auto configPath = buildPath(directory, guardName ~ ".ini");
    auto eventPath = logPath;
    recordStep(eventPath, "合并日志：" ~ logPath ~ "（守护与测试共用，测试后保留）", "日志");
    copy(buildPath(thisExePath.dirName, "dservice.exe"), executable);
    auto missingConfig = execute([executable, "--install"]);
    assert(missingConfig.status == 1);
    assert(missingConfig.output.canFind("请先创建配置文件：" ~ configPath));
    auto help = execute([executable, "--help"]);
    assert(help.status == 0 && help.output.canFind("用法：" ~ guardName ~ ".exe"));

    string[] workerPaths;
    foreach(name; demoNames)
    {
        auto path = buildPath(directory, name);
        workerPaths ~= path;
    }
    auto missingPath = buildPath(directory, "missing.exe");
    assert(!exists(missingPath), "missing.exe 必须不存在，测试不会修改该文件");
    auto shortPath = buildPath(directory, shortDemoName);
    write(configPath, "[service]\nmaxRetries=2\n[programs]\napp1=" ~ demoNames[0] ~
        "\napp2=" ~ demoNames[1] ~ "\napp3=missing.exe\napp4=" ~ shortDemoName ~ "\n");
    HANDLE supervisor;
    HANDLE[2] workers;
    DWORD[2] retainedPids;
    scope(exit)
    {
        terminate(supervisor);
        foreach(ref worker; workers) terminate(worker);
        cleanupWorkers(workerPaths ~ [shortPath]);
    }
    supervisor = launch(executable, "--console");
    auto firstGuardPid = GetProcessId(supervisor);
    recordStep(eventPath, "首次启动守护，PID=" ~ firstGuardPid.to!string);
    foreach(index, path; workerPaths)
    {
        auto prefix = "启动成功：" ~ path;
        waitUntil(() => loggedPids(readLog(logPath), prefix).length == 1, "demo 未启动：" ~ path);
        workers[index] = openWorker(loggedPids(readLog(logPath), prefix)[0], path);
        assert(workers[index] !is null && WaitForSingleObject(workers[index], 0) == WAIT_TIMEOUT, "demo 未存活：" ~ path);
    }
    foreach(index, path; workerPaths)
    {
        auto prefix = "启动成功：" ~ path;
        auto oldPid = GetProcessId(workers[index]);
        auto demoLabel = index == 0 ? "demo-a" : "demo-b";
        recordStep(eventPath, "结束 " ~ demoLabel ~ "：" ~ path ~ "，PID=" ~ oldPid.to!string);
        terminate(workers[index]);
        waitUntil(() => loggedPids(readLog(logPath), prefix).length == 2, "demo 被杀后未重新拉起：" ~ path);
        retainedPids[index] = loggedPids(readLog(logPath), prefix)[$ - 1];
        workers[index] = openWorker(retainedPids[index], path);
        assert(workers[index] !is null && WaitForSingleObject(workers[index], 0) == WAIT_TIMEOUT);
        assert(readLog(logPath).canFind("程序已退出：" ~ path));
        recordStep(eventPath, "守护已重新拉起 " ~ demoLabel ~ "：" ~ path ~ "，原 PID=" ~ oldPid.to!string ~
            "，当前 PID=" ~ retainedPids[index].to!string);
        auto otherIndex = 1 - index;
        assert(WaitForSingleObject(workers[otherIndex], 0) == WAIT_TIMEOUT, "杀死一个 demo 不应影响另一个");
    }
    waitUntil(() => readLog(logPath).canFind("放弃重启：" ~ missingPath), "缺失程序未在预算耗尽后放弃");
    waitUntil(() => readLog(logPath).canFind("放弃重启：" ~ shortPath), "立即退出程序未在预算耗尽后放弃");
    assert(countLines(readLog(logPath), "创建进程失败：" ~ missingPath) == 3, "首次启动加两次重试应恰好三次");
    assert(loggedPids(readLog(logPath), "启动成功：" ~ shortPath).length == 3, "短命程序不能因创建成功重置预算");
    // 等待健康程序的一次真实恢复，确认放弃后仍继续监控且不再尝试失败程序。
    terminate(workers[0]);
    waitUntil(() => loggedPids(readLog(logPath), "启动成功：" ~ workerPaths[0]).length == 3, "放弃其他程序后健康程序应继续恢复");
    retainedPids[0] = loggedPids(readLog(logPath), "启动成功：" ~ workerPaths[0])[$ - 1];
    workers[0] = openWorker(retainedPids[0], workerPaths[0]);
    assert(workers[0] !is null && WaitForSingleObject(workers[1], 0) == WAIT_TIMEOUT);
    assert(countLines(readLog(logPath), "创建进程失败：" ~ missingPath) == 3);
    assert(loggedPids(readLog(logPath), "启动成功：" ~ shortPath).length == 3);
    recordStep(eventPath, "缺失程序和立即退出程序均恰好尝试三次后放弃，健康 demo 继续受监控");

    recordStep(eventPath, "开始验证守护自身重启：结束守护 PID=" ~ firstGuardPid.to!string);
    terminate(supervisor);
    foreach(index, worker; workers)
    {
        assert(WaitForSingleObject(worker, 0) == WAIT_TIMEOUT, "停止守护后必须保留两个 demo");
        recordStep(eventPath, "守护已退出，demo 仍存活：" ~ workerPaths[index] ~ "，PID=" ~ retainedPids[index].to!string);
    }
    supervisor = launch(executable, "--console");
    recordStep(eventPath, "测试重新启动守护，原 PID=" ~ firstGuardPid.to!string ~
        "，当前 PID=" ~ GetProcessId(supervisor).to!string);
    foreach(index, path; workerPaths)
    {
        waitUntil(() => readLog(logPath).canFind("接管已有程序：" ~ path ~ "，PID=" ~ retainedPids[index].to!string),
            "重启守护后未接管 demo：" ~ path);
        assert(loggedPids(readLog(logPath), "启动成功：" ~ path).length == (index == 0 ? 3 : 2), "接管时不应重复启动");
        recordStep(eventPath, "重启后的守护已接管：" ~ path ~ "，PID 保持为 " ~ retainedPids[index].to!string);
    }
    waitUntil(() => countLines(readLog(logPath), "创建进程失败：" ~ missingPath) == 4, "重启守护应重置失败预算");
    terminate(supervisor);
    foreach(index, path; workerPaths)
    {
        assert(WaitForSingleObject(workers[index], 0) == WAIT_TIMEOUT, "再次停止后 demo 仍应存活：" ~ path);
        terminate(workers[index]);
        recordStep(eventPath, "已验证启动、杀死后重启、保留、接管和最终杀死清理：" ~ path);
    }
}

// 按完整事件前缀统计次数，避免依赖 PID 或重试时间猜测。
private size_t countLines(string text, string prefix)
{
    size_t count;
    foreach(line; text.splitLines) if(line.canFind(prefix)) ++count;
    return count;
}

unittest
{
    auto iniPath = `C:\配置 目录\guard.ini`;
    auto config = parseConfig("\xEF\xBB\xBF; 注释\n# 注释\n\n[programs]\napp1=demo.exe\napp2=\"..\\中文 空格\\b.exe\"\n", iniPath);
    assert(config.maxRetries == 5);
    assert(config.paths == [`C:\配置 目录\demo.exe`, `C:\中文 空格\b.exe`]);
    foreach(limit; [0, 12])
        assert(parseConfig("[service]\nmaxRetries=" ~ limit.to!string ~ "\n[programs]\napp1=a.exe", iniPath).maxRetries == limit);
    assert(parseConfig("[programs]\napp1=C:\\Apps\\one.exe\napp2=c:/apps/./one.exe", iniPath).paths.length == 1);
    foreach(value; ["", "-1", "+1", "abc", "1.5", "4294967296", "999999999999999999999"])
        assertThrown!Exception(parseConfig("[service]\nmaxRetries=" ~ value ~ "\n[programs]\napp1=a.exe", iniPath));
    foreach(value; ["", "\"", "bad\0.exe", "C:relative.exe"])
        assertThrown!Exception(parseConfig("[programs]\napp1=" ~ value, iniPath));
    assertThrown!Exception(parseConfig("[programs]\napp1=guard.exe", iniPath, `C:\配置 目录\guard.exe`));
    assertThrown!Exception(parseConfig("\n; 空配置", iniPath));
    assertThrown!Exception(parseConfig("app1=a.exe", iniPath));
    assertThrown!Exception(parseConfig("[service]\nmaxRetries=1\nmaxRetries=2\n[programs]\napp1=a.exe", iniPath));
    foreach(key; ["demoA", "app0", "app01", "app-1", "app4294967296", "app2"])
        assertThrown!Exception(parseConfig("[programs]\n" ~ key ~ "=a.exe", iniPath));
    assertThrown!Exception(parseConfig("[programs]\napp1=a.exe\napp1=b.exe", iniPath));
    string orderedText = "[programs]\n";
    foreach_reverse(number; 1 .. 13) orderedText ~= "app" ~ number.to!string ~ "=" ~ number.to!string ~ ".exe\n";
    auto ordered = parseConfig(orderedText, iniPath);
    foreach(index, path; ordered.paths) assert(path.baseName == (index + 1).to!string ~ ".exe");

}

// 默认预算为五次重试，首次启动不计入重试次数。
unittest
{
    RetryBudget budget;
    assert(budget.maxRetries == 5 && budget.retries == 0);
    assert(budget.initialAttempt && !budget.abandoned);
    assert(budget.beginAttempt());
    assert(!budget.initialAttempt && budget.retries == 0);
    foreach(attempt; 1 .. 6)
    {
        assert(budget.beginAttempt(), "默认预算应允许五次重试");
        assert(budget.retries == attempt && !budget.abandoned);
    }
    assert(!budget.beginAttempt() && budget.abandoned);
}

// 零预算仍允许首次启动；首次失败后不允许恢复。
unittest
{
    auto budget = RetryBudget(0);
    assert(budget.beginAttempt());
    assert(budget.retries == 0 && !budget.abandoned);
    assert(!budget.beginAttempt() && budget.abandoned);
    assert(budget.retries == 0);
}

// 零预算下即使首次启动稳定存活，退出后也不能重新启动。
unittest
{
    auto budget = RetryBudget(0);
    assert(budget.beginAttempt());
    budget.observedAlive();
    assert(!budget.initialAttempt && budget.retries == 0);
    assert(!budget.beginAttempt() && budget.abandoned);
}

// 连续首次失败及后续失败共允许一次初始尝试加 n 次重试。
unittest
{
    foreach(limit; [1u, 2u, 12u])
    {
        auto budget = RetryBudget(limit);
        assert(budget.beginAttempt());
        assert(budget.retries == 0);
        foreach(attempt; 1 .. limit + 1)
        {
            assert(budget.beginAttempt(), "有限预算不得提前耗尽");
            assert(budget.retries == attempt && !budget.abandoned);
        }
        assert(!budget.beginAttempt() && budget.abandoned);
        assert(budget.retries == limit);
    }
}

// 创建成功不属于存活观察；连续立即退出时预算不会自动重置。
unittest
{
    auto budget = RetryBudget(2);
    assert(budget.beginAttempt());
    // 对应 checkProgram 未观察到 WAIT_TIMEOUT 的连续启动机会。
    assert(budget.beginAttempt() && budget.retries == 1);
    assert(budget.beginAttempt() && budget.retries == 2);
    assert(!budget.beginAttempt() && budget.abandoned);
}

// 稳定存活后退出只有 n 次恢复机会，不会重新获得免费的首次启动。
unittest
{
    auto budget = RetryBudget(2);
    assert(budget.beginAttempt());
    budget.observedAlive();
    assert(!budget.initialAttempt && budget.retries == 0);
    assert(budget.beginAttempt() && budget.retries == 1);
    assert(budget.beginAttempt() && budget.retries == 2);
    assert(!budget.beginAttempt() && budget.abandoned);
}

// 消耗部分或全部重试机会后观察到存活，都恢复完整预算且可多轮恢复。
unittest
{
    auto budget = RetryBudget(2);
    assert(budget.beginAttempt());
    foreach(consumed; [1u, 2u, 2u])
    {
        foreach(attempt; 0 .. consumed) assert(budget.beginAttempt());
        assert(budget.retries == consumed && !budget.abandoned);
        budget.observedAlive();
        assert(budget.retries == 0 && !budget.initialAttempt && !budget.abandoned);
    }
    assert(budget.beginAttempt() && budget.retries == 1);
    assert(budget.beginAttempt() && budget.retries == 2);
    assert(!budget.beginAttempt() && budget.abandoned);
}

// 耗尽后每次检查都拒绝启动，保持放弃状态且不继续累计计数。
unittest
{
    auto budget = RetryBudget(2);
    foreach(attempt; 0 .. 3) assert(budget.beginAttempt());
    foreach(check; 0 .. 10)
    {
        assert(!budget.beginAttempt() && budget.abandoned);
        assert(budget.retries == 2 && !budget.initialAttempt);
    }
}

// 各程序独立持有预算，一个程序的消耗、重置及放弃均不改变另一个。
unittest
{
    auto first = RetryBudget(2);
    auto second = RetryBudget(2);
    assert(first.beginAttempt());
    assert(first.beginAttempt() && first.retries == 1);
    assert(second.initialAttempt && second.retries == 0 && !second.abandoned);
    assert(second.beginAttempt());
    assert(second.beginAttempt() && second.retries == 1);
    first.observedAlive();
    assert(first.retries == 0 && second.retries == 1);
    assert(first.beginAttempt());
    assert(first.beginAttempt());
    assert(!first.beginAttempt() && first.abandoned);
    assert(second.retries == 1 && !second.abandoned);
    second.observedAlive();
    assert(first.abandoned && first.retries == 2);
    assert(second.beginAttempt() && second.retries == 1);
    assert(second.beginAttempt() && second.retries == 2);
    assert(!second.beginAttempt() && second.abandoned);
}
