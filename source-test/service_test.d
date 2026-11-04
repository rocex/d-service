module service_test;

version(unittest):

import app : parseConfig;
import core.sys.windows.windows;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : assertThrown;
import std.file : copy, exists, mkdir, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath, dirName;
import std.file : thisExePath;
import std.string : indexOf, splitLines;
import std.utf : toUTF16, toUTF16z;

/// 启动测试进程，返回用于等待和清理的进程句柄。
private HANDLE launch(string executable, string argument)
{
    STARTUPINFOW startup;
    startup.cb = cast(DWORD) startup.sizeof;
    PROCESS_INFORMATION info;
    auto command = ("\"" ~ executable ~ "\" " ~ argument ~ "\0").toUTF16.dup;
    assert(CreateProcessW(executable.toUTF16z, command.ptr, null, null, FALSE,
        CREATE_NO_WINDOW, null, null, &startup, &info), "启动测试进程失败");
    CloseHandle(info.hThread);
    return info.hProcess;
}

/// 终止并等待仅由测试创建的进程，不操作系统服务。
private void terminate(HANDLE process)
{
    if (process is null)
        return;
    TerminateProcess(process, 0);
    WaitForSingleObject(process, 5000);
    CloseHandle(process);
}

/// 等待条件满足，最长十五秒。
private void waitUntil(bool delegate() condition, string message)
{
    foreach (attempt; 0 .. 150)
    {
        if (condition())
            return;
        Sleep(100);
    }
    assert(false, message);
}

/// 日志尚未创建时返回空字符串。
private string readLog(string path)
{
    return exists(path) ? readText(path) : "";
}

/// 读取指定事件对应的 PID 列表。
private DWORD[] loggedPids(string text, string prefix)
{
    DWORD[] result;
    foreach (line; text.splitLines)
    {
        if (!line.canFind(prefix))
            continue;
        auto position = line.indexOf("PID=");
        if (position >= 0)
            result ~= line[position + 4 .. $].to!DWORD;
    }
    return result;
}

unittest
{
    // 复制的测试可执行文件充当长驻工作进程，无需另行维护测试脚本。
    if (thisExePath.canFind("worker.exe"))
    {
        Sleep(INFINITE);
        return;
    }
    auto paths = parseConfig("\xEF\xBB\xBF C:\\Apps\\one.exe\r\n\r\n\"D:\\含空格 目录\\two.exe\"\n");
    assert(paths == ["C:\\Apps\\one.exe", "D:\\含空格 目录\\two.exe"]);
    assert(parseConfig("C:\\Apps\\one.exe\nc:/apps/one.exe").length == 1);
    assertThrown!Exception(parseConfig("relative.exe"));
    assertThrown!Exception(parseConfig("\r\n  \n"));
    assertThrown!Exception(parseConfig("C:\\app.exe --flag\""));
    assertThrown!Exception(parseConfig("C:\\bad\0.exe"));
}

unittest
{
    // 被守护进程不带参数，依靠独立文件名识别测试工作进程。
    if (thisExePath.canFind("worker.exe"))
    {
        Sleep(INFINITE);
        return;
    }
    auto directory = buildPath(tempDir(), "dservice-test-" ~ GetCurrentProcessId().to!string ~ "-" ~ GetTickCount().to!string);
    mkdir(directory);
    scope(exit) rmdirRecurse(directory);
    auto executable = buildPath(directory, "守护 test.exe");
    auto workerPath = buildPath(directory, "worker.exe");
    auto logPath = buildPath(directory, "守护 test.log");
    auto productionExecutable = buildPath(thisExePath.dirName, "dservice.exe");
    assert(exists(productionExecutable), "请先执行 dub build --build=release");
    copy(productionExecutable, executable);
    copy(thisExePath, workerPath);
    auto missingPath = buildPath(directory, "missing.exe");
    write(buildPath(directory, "守护 test.conf"), workerPath ~ "\r\n" ~ missingPath ~ "\r\n");
    HANDLE supervisor;
    HANDLE worker;
    scope(exit)
    {
        terminate(supervisor);
        terminate(worker);
        // 断言失败时也清理日志中所有由本测试创建的工作进程。
        foreach (pid; loggedPids(readLog(logPath), "启动成功：" ~ workerPath))
        {
            auto process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pid);
            terminate(process);
        }
    }
    supervisor = launch(executable, "--console");
    auto startedPrefix = "启动成功：" ~ workerPath;
    waitUntil(() => loggedPids(readLog(logPath), startedPrefix).length == 1, "程序未启动");
    auto firstPid = loggedPids(readLog(logPath), startedPrefix)[0];
    worker = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, firstPid);
    assert(worker !is null && WaitForSingleObject(worker, 0) == WAIT_TIMEOUT);
    terminate(worker);
    worker = null;
    waitUntil(() => loggedPids(readLog(logPath), startedPrefix).length >= 2, "程序退出后未重新拉起");
    auto retainedPid = loggedPids(readLog(logPath), startedPrefix)[$ - 1];
    worker = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, retainedPid);
    assert(worker !is null);
    assert(readLog(logPath).canFind("程序已退出：" ~ workerPath));
    size_t failureCount;
    foreach (line; readLog(logPath).splitLines)
        if (line.canFind("创建进程失败：" ~ missingPath)) ++failureCount;
    assert(failureCount >= 2, "启动失败应持续重试且不影响其他程序");
    terminate(supervisor);
    supervisor = null;
    assert(WaitForSingleObject(worker, 0) == WAIT_TIMEOUT, "停止守护后必须保留工作进程");
    supervisor = launch(executable, "--console");
    waitUntil(() => readLog(logPath).canFind("接管已有程序：" ~ workerPath ~ "，PID=" ~ retainedPid.to!string),
        "重启守护后未接管原有程序");
    assert(loggedPids(readLog(logPath), startedPrefix).length == 2, "接管时不应重复启动");
    terminate(supervisor);
    supervisor = null;
    assert(WaitForSingleObject(worker, 0) == WAIT_TIMEOUT, "再次停止后工作进程仍应存活");
}
