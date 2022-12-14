import interpreter;
import ast;
import std.container;
import std.range;
import token;
import app;
import std.format;
import std.typecons : Tuple;
import tokentype;

class Resolver : StmtVisitor, ExprVisitor {

    private alias VarRef = Tuple!(VarState, "state", int, "line");

    private Interpreter interpreter;
    private SList!(VarRef[string]) scopes;
    private SList!(BlockType) blocks;
    private FunctionType currentFunction = FunctionType.NONE;
    private LoopType currentLoop = LoopType.NONE;
    private ClassType currentClass = ClassType.NONE;
    private BlockType currentBlock = BlockType.EXEC;

    private enum VarState {
        DECLARED,
        DEFINED,
        REFERENCED
    }

    private enum FunctionType {
        NONE,
        FUN,
        METHOD,
        INITIALIZER
    }

    private enum LoopType {
        NONE,
        WHILE
    }

    private enum ClassType {
        NONE,
        CLASS,
        METACLASS,
        SUBCLASS
    }

    private enum BlockType {
        EXEC,
        CALL
    }

    this(Interpreter interpreter) {
        this.interpreter = interpreter;
        this.scopes = SList!(VarRef[string])();
        this.blocks = SList!(BlockType)();
    }

    void resolve(T)(T[] statements...) {
        foreach(statement; statements) {
            statement.accept(this);
        }
    }

    void beginScope(BlockType type = BlockType.EXEC) {
        scopes.insertFront(null);
        blocks.insertFront(type);
    }

    private void endScope() {
        foreach(sco; scopes.front().byPair) {
            if(sco.value.state != VarState.REFERENCED) {
                Lox.warning(mkToken(sco.key, sco.value),
                    format("Variable declared but never referenced"));
            }
        }
        scopes.removeFront();
        blocks.removeFront();
    }

    private TokenI mkToken(string name, VarRef vref) {
        return TokenI(TokenType.IDENTIFIER, name, null, vref.line);
    }

    private void declare(TokenI name) {
        if(scopes.empty()) return;

        if(name.lexeme in scopes.front()) {
            Lox.error(name, "Already a variable with this name in this scope.");
        }
        scopes.front()[name.lexeme] = VarRef(VarState.DECLARED, name.line);
    }

    private void define(TokenI name) {
        if(scopes.empty()) return;

        scopes.front()[name.lexeme].state = VarState.DEFINED;
    }

    private void resolveLocal(Expr expr, TokenI name, bool lvalue = false) {
        foreach(i, sco; scopes[].enumerate()) {
            if(auto local = name.lexeme in sco) {
                if (!lvalue && (*local).state == VarState.DECLARED) {
                    bool call = false;
                    foreach(bl; blocks[].take(i)) {
                        if (bl == BlockType.CALL) {
                            call = true;
                            break;
                        }
                    }
                    if (!call) Lox.error(name, "Attempt to reference undefined local variable");
                }
                interpreter.resolve(expr, i);
                if ((*local).state != VarState.REFERENCED) {
                    (*local).state = lvalue ? VarState.DEFINED : VarState.REFERENCED;
                }
                break;
            }
        }
    }

    void visit(Print _print) {
        resolve(_print.expression);
    }

    void visit(Expression _expression) {
        resolve(_expression.expression);
    }

    void visit(Var stmt) {
        declare(stmt.name);
        if (stmt.initializer !is null) {
            resolve(stmt.initializer);
            define(stmt.name);
        }
    }

    void visit(Block stmt) {
        beginScope();
        resolve(stmt.statements);
        endScope();
    }

    void visit(If _if) {
        resolve(_if.condition);
        resolve(_if.thenBranch);
        if (_if.elseBranch !is null) resolve(_if.elseBranch);
    }

    void visit(While _while) {
        resolve(_while.condition);
        LoopType enclosingLoop = currentLoop;
        currentLoop = LoopType.WHILE;
        resolve(_while.bod);
        currentLoop = enclosingLoop;
    }

    void visit(Break _break) {
        if (currentLoop == LoopType.NONE) {
            Lox.error(_break.keyword, "Can't break outside a loop.");
        }
    }

    void visit(Return _return) {
        if (currentFunction == FunctionType.NONE) {
            Lox.error(_return.keyword, "Can't return from top-level code.");
        }
        if (_return.value !is null) {
            if (currentFunction == FunctionType.INITIALIZER) {
                Lox.error(_return.keyword,  "Can't return value from initializer method");
            }
            resolve(_return.value);
        }
    }

    void visit(Ternary _ternary) {
        resolve(_ternary.left);
        resolve(_ternary.middle);
        resolve(_ternary.right);
    }

    void visit(Binary _binary) {
        resolve(_binary.left);
        resolve(_binary.right);
    }

    void visit(Grouping _grouping) {
        resolve(_grouping.expression);
    }

    void visit(Literal _) {}

    void visit(Unary _unary) {
        resolve(_unary.right);
    }

    void visit(Variable expr) {
        resolveLocal(expr, expr.name);
    }
    void visit(Assign expr) {
        resolve(expr.value);
        resolveLocal(expr, expr.name, true);
    }

    void visit(Logical _logical) {
        resolve(_logical.left);
        resolve(_logical.right);
    }

    void visit(Call _call) {
        resolve(_call.callee);

        foreach(arg; _call.arguments) {
            resolve(arg);
        }
    }

    void visit(Function expr) {
        resolveFunction(expr, FunctionType.FUN);
    }

    private void resolveFunction(Function expr, FunctionType type) {
        FunctionType enclosingFunction = currentFunction;
        currentFunction = type;
        beginScope(BlockType.CALL);
        foreach (param; expr.params) {
            declare(param);
            define(param);
        }
        resolve(expr.body);
        endScope();
        currentFunction = enclosingFunction;
    }

    void visit(Class cl) {
        ClassType enclosingClass = currentClass;
        currentClass = ClassType.METACLASS;

        beginScope();
        scopes.front()["this"] = VarRef(VarState.REFERENCED, 0);

        resolveMethods(cl.classmethods);

        endScope();

        currentClass = ClassType.CLASS;
        
        if(cl.superclass) {
            resolve(cl.superclass);
            currentClass = ClassType.SUBCLASS;
            beginScope();
            scopes.front()["super"] = VarRef(VarState.REFERENCED, 0);
        }

        beginScope(BlockType.CALL);
        scopes.front()["this"] = VarRef(VarState.REFERENCED, 0);

        resolveMethods(cl.methods);

        endScope();
        
        if(cl.superclass) endScope();
        currentClass = enclosingClass;
    }

    void resolveMethods(Var[] methods) {
        foreach(method; methods) {
            if (auto fun = cast(Function) method.initializer) {
                FunctionType declaration = FunctionType.METHOD;
                if (method.name.lexeme == "init") {
                    declaration = FunctionType.INITIALIZER;
                    if (currentClass == ClassType.METACLASS && fun.params.length > 0) {
                        Lox.error(fun.params[0], "class initializer cannot have arguments");
                    }
                }
                resolveFunction(fun, declaration);
            } else {
                resolve(method.initializer);
            }
        }

    }

    void visit(Get get) {
        resolve(get.object);
    }

    void visit(Set set) {
        resolve(set.value);
        resolve(set.object);
    }

    void visit(This th) {
        if (currentClass == ClassType.NONE
                || currentFunction == FunctionType.NONE) {
            Lox.error(th.keyword, "'This' not allowed here");
            return;
        }
        resolveLocal(th, th.keyword);
    }

    void visit(Super th) {
        if (currentClass != ClassType.SUBCLASS
                || currentFunction == FunctionType.NONE) {
            Lox.error(th.keyword, "'Super' not allowed here");
            return;
        }
        resolveLocal(th, th.keyword);
    }
}
