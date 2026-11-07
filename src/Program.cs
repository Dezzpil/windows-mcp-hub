// ============================================================================
//  MCP Hub — однофайловая Windows-обёртка над mcp-hub.ps1
//
//  Извлекает встроенный скрипт во временную папку и запускает его через
//  PowerShell без ограничений ExecutionPolicy. Конфиг mcp-hub.config.json
//  создаётся рядом с exe (передаётся через MCP_HUB_HOME).
//
//  Сборка (Linux, mono-mcs):
//    mcs -target:exe -out:mcp-hub.exe -win32icon:mcp-hub.ico \
//        -r:System.dll -resource:mcp-hub.ps1,mcp-hub.ps1 src/Program.cs
// ============================================================================
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

[assembly: AssemblyTitle("MCP Hub")]
[assembly: AssemblyProduct("MCP Hub")]
[assembly: AssemblyDescription("MCP manager for ComfyUI and Blender")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace McpHub
{
    static class Program
    {
        static int Main(string[] args)
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            string script;
            using (Stream s = asm.GetManifestResourceStream("mcp-hub.ps1"))
            {
                if (s == null)
                {
                    Console.Error.WriteLine("Внутри exe не найден скрипт mcp-hub.ps1 — сборка повреждена.");
                    return 1;
                }
                using (StreamReader r = new StreamReader(s, Encoding.UTF8))
                {
                    script = r.ReadToEnd();
                }
            }

            string home = Environment.GetEnvironmentVariable("MCP_HUB_HOME");
            if (string.IsNullOrEmpty(home))
                home = Path.GetDirectoryName(asm.Location);

            string tmp = Path.Combine(Path.GetTempPath(),
                "mcp-hub-" + Guid.NewGuid().ToString("N") + ".ps1");
            // UTF-8 с BOM — иначе Windows PowerShell 5.1 исказит кириллицу
            File.WriteAllText(tmp, script, new UTF8Encoding(true));

            try
            {
                string ps = Environment.GetEnvironmentVariable("MCP_HUB_PWSH");
                if (string.IsNullOrEmpty(ps))
                    ps = "powershell.exe";

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = ps;
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \""
                                + tmp + "\"" + QuoteArgs(args);
                psi.UseShellExecute = false;
                psi.EnvironmentVariables["MCP_HUB_HOME"] = home;

                Process p;
                try
                {
                    p = Process.Start(psi);
                }
                catch (Exception e)
                {
                    Console.Error.WriteLine("Не удалось запустить PowerShell (" + ps + "): " + e.Message);
                    return 1;
                }
                p.WaitForExit();
                return p.ExitCode;
            }
            finally
            {
                try { File.Delete(tmp); } catch (IOException) { }
            }
        }

        static string QuoteArgs(string[] args)
        {
            StringBuilder sb = new StringBuilder();
            foreach (string a in args)
            {
                sb.Append(" \"").Append(a.Replace("\"", "\"\"")).Append("\"");
            }
            return sb.ToString();
        }
    }
}
