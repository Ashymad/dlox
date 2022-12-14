import std.stdio;
import std.file;
import std.container;
import token;
import scanner;
import deimos.linenoise;
import std.string;
import std.conv;
import keywords;
import tokentype;
import ast;
import parser;
import error;
import interpreter;
import resolver;

int main(string[] args) {
    Lox lox = new Lox;
    if (args.length > 2) {
        writeln("Usage: dlox [script]");
        return 64;
    } else if (args.length == 2) {
        lox.runFile(args[1]);
    } else {
        lox.runPrompt();
    }
    if (lox.hadRuntimeError) return 70;
    if (lox.hadError) return 65;
    return 0;
}

class Lox {
    static bool hadError = false;
    static bool hadRuntimeError = false;

    Resolver resolver;
    Interpreter interpreter;

    this() {
        interpreter = new Interpreter();
        resolver = new Resolver(interpreter);
    }

    extern(C) static void completion(const char *buf, linenoiseCompletions *lc) {
        auto bufs = fromStringz(buf);
        auto lastsp = 1 + lastIndexOfAny(bufs, [
                ' ', '\t', '=', '+', '-', '<', '>',
                '/', '*', '(', ')', '{', '}']);
        auto klen = bufs.length - lastsp;
        if (bufs.length <= 0) return;

        foreach (key; keywords.keywords.keys) {
            if (klen <= key.length && bufs[lastsp..$] == key[0..klen]) {
                linenoiseAddCompletion(lc, toStringz(bufs[0..lastsp] ~ key));
            }
        }
    }

    void runFile(string file) {
        run(to!(char[])(readText(file)));
    }

    void runPrompt() {
        char* line;
        const char* history = ".dlox_history";

        linenoiseSetCompletionCallback(&completion);
        linenoiseHistoryLoad(history);

        while((line = linenoise("lox> ")) !is null) {
            if (line[0] != '\0') {
                linenoiseHistoryAdd(line);
                linenoiseHistorySave(history);
            }
            run(fromStringz(line));
            hadError = false;
        }
    }

    void run(char[] source) {
        Scanner scanner = new Scanner(source);
        auto tokens = scanner.scanTokens();
        if(hadError) return;

        Parser parser = new Parser(tokens);
        auto expression = parser.parse();
        if(hadError) return;

        resolver.resolve(expression);
        if(hadError) return;

        auto result = interpreter.interpret(expression);
        if(hadError) return;

        if (!result.empty()) writeln(result);

    }

    static void error(int line, string msg) {
        report(line, "", msg);
    }

    static void error(const TokenI token, string message) {
        if (token.type == TokenType.EOF) {
            report(token.line, " at end", message);
        } else {
            report(token.line, " at '" ~ token.lexeme ~ "'", message);
        }
    }

    static void warning(const TokenI token, string message) {
        if (token.type == TokenType.EOF) {
            report(token.line, " at end", message, true);
        } else {
            report(token.line, " at '" ~ token.lexeme ~ "'", message, true);
        }
    }

    static void error(RuntimeError err) {
        error(err.token, err.msg);
        hadRuntimeError = true;
    }


    static void report(int line, string where, string msg, bool warning = false) {
        stderr.writefln("[line %s] %s%s: %s", line, warning ? "Warning" : "Error", where, msg);
        if (!warning) this.hadError = true;
    }
}

