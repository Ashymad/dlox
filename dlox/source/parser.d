import token;
import tokentype;
import std.container;
import std.variant : Variant;
import ast;
import app;

/*
program        → statement* EOF ;
declaration    → classDecl
               | funDecl
               | varDecl
               | statement ;
varDecl        → "var" IDENTIFIER ( "=" expression )? ";" ;
statement      → exprStmt
               | forStmt
               | ifStmt
               | printStmt 
               | returnStmt
               | whileStmt
               | breakStmt
               | block ;
returnStmt     → "return" expression? ";" ;
funDecl        → "fun" IDENTIFIER function ;
function       → "(" parameters? ")" block ;
classDecl      → "class" IDENTIFIER class ;
class          → ( "<" IDENTIFIER )? "{" ( "class"? IDENTIFIER ( function | "=" expression ) )* "}" ;
parameters     → IDENTIFIER ( "," IDENTIFIER )* ;
forStmt        → "for" "(" ( varDecl | exprStmt | ";" )
                 expression? ";"
                 expression? ")" statement ;
whileStmt      → "while" "(" expression ")" statement ;
ifStmt         → "if" "(" expression ")" statement
               ( "else" statement )? ;
block          → "{" declaration* "}" ;
exprStmt       → expression ";" ;
printStmt      → "print" expression ";" ;
expression     → separator ;
separator      → assignment ( "," assignment )* ;
assignment     → ( call "." )? IDENTIFIER "=" assignment
               | ternary ;
ternary        → logic_or ( "?" expression ":" ternary )? ;
logic_or       → logic_and ( "or" logic_and )* ;
logic_and      → equality ( "and" equality )* ;
equality       → comparison ( ( "!=" | "==" ) comparison )* ;
comparison     → term ( ( ">" | ">=" | "<" | "<=" ) term )* ;
term           → factor ( ( "-" | "+" ) factor )* ;
factor         → unary ( ( "/" | "*" ) unary )* ;
unary          → ( "!" | "-" | "ast" ) unary
               | call ;
call           → funExpr ( "(" arguments? ")" | "." IDENTIFIER )* ;
funExpr        → "fun" function | classExpr ;
classExpr      → "class" class | primary ;
primary        → NUMBER | STRING | "true" | "false" | "nil" | "this" | "super"
               | "(" expression ")" | IDENTIFIER ;
arguments      → expression ( "," expression )* ;
*/

class Parser {
    private static class ParseError : Exception {
        this(string msg, string file = __FILE__, size_t line = __LINE__) {
            super(msg, file, line);
        }
    }

    private Array!TokenI tokens;
    private int current = 0;

    this(Array!TokenI tokens) {
        this.tokens = tokens;
    }

    Stmt[] parse() {
        Stmt[] statements;
        while (!isAtEnd()) {
            statements ~= declaration();
        }
        return statements;
    }

    private Stmt declaration() {
        try {
            if (match(TokenType.VAR))
                return varDeclaration();
            if (check(TokenType.FUN) && peekNext().type == TokenType.IDENTIFIER) {
                advance();
                return statement!(Var)(advance(), fun());
            } else if (check(TokenType.CLASS) && peekNext().type == TokenType.IDENTIFIER) {
                advance();
                return statement!(Var)(advance(), _class());
            } else {
                return matchStatement();
            }
        } catch (ParseError err) {
            synchronize();
            return null;
        }
    }

    private Expr fun() {
        consume(TokenType.LEFT_PAREN, "Expect '(' at function declaration.");
        TokenI[] parameters = [];
        if (!check(TokenType.RIGHT_PAREN)) {
            do {
                if (parameters.length >= 255) {
                    error(peek(), "Can't have more than 255 parameters.");
                }

                parameters ~= consume(TokenType.IDENTIFIER, "Expect parameter name.");
            } while (match(TokenType.COMMA));
        }
        consume(TokenType.RIGHT_PAREN, "Expect ')' after parameters.");
        consume(TokenType.LEFT_BRACE, "Expect '{' before function body.");
        Stmt[] bod = block();
        return new Function(parameters, bod);
    }

    private Expr _class() {
        Variable superclass = null;
        if (match(TokenType.LESS)) {
            consume(TokenType.IDENTIFIER, "Expect superclass name.");
            superclass = new Variable(previous());
        }

        consume(TokenType.LEFT_BRACE, "Expect '{' before class body.");

        Var[] fields;
        Var[] classfields;

        while (!isAtEnd() && !check(TokenType.RIGHT_BRACE)) {
            Var[]* lfields = match(TokenType.CLASS) ? &classfields : &fields;
            consume(TokenType.IDENTIFIER, "Expect field name.");
            TokenI name = previous();
            if (check(TokenType.LEFT_PAREN)) {
              *lfields ~= statement!(Var)(name, fun());
            } else if (match(TokenType.EQUAL)) {
              *lfields ~= statement!(Var)(name, expression());
            } else {
                Lox.error(name, "Expect field declaration");
            }
        }

        consume(TokenType.RIGHT_BRACE, "Expect '}' after class.");

        return new Class(fields, classfields, superclass);
    }
    
    private Stmt varDeclaration() {
        TokenI name = consume(TokenType.IDENTIFIER, "Expect variable name.");
        Expr initializer = match(TokenType.EQUAL) ? expression() : null;

        return statement!(Var)(name, initializer);
    }

    private Stmt matchStatement() {
        if (match(TokenType.FOR))
            return forStatement();
        if (match(TokenType.IF))
            return ifStatement();
        if (match(TokenType.PRINT))
            return statement!(Print)(expression());
        if (match(TokenType.WHILE))
            return whileStatement();
        if (match(TokenType.RETURN))
            return returnStatement();
        if (match(TokenType.LEFT_BRACE))
            return statement!(Block)(block());
        if (match(TokenType.BREAK))
            return breakStatement();
        return statement!(Expression)(expression());
    }
    
    private Stmt breakStatement() {
        return statement!(Break)(previous());
    }

    private Stmt returnStatement() {
        TokenI keyword = previous();
        Expr value = null;
        if (!isAtEnd() && !check(TokenType.SEMICOLON) && !check(TokenType.RIGHT_BRACE)) {
            value = expression();
        }
        return statement!(Return)(keyword, value);
    }

    private Stmt forStatement() {
        consume(TokenType.LEFT_PAREN, "Expect '(' after 'for'.");

        Stmt initializer;

        if (match(TokenType.SEMICOLON)) {
            initializer = null;
        } else if (match(TokenType.VAR)) {
            initializer = varDeclaration();
        } else {
            initializer = statement!(Expression)(expression());
        }

        Expr condition = null;
        if (!check(TokenType.SEMICOLON)) {
            condition = expression();
        }
        consume(TokenType.SEMICOLON, "Expect ';' after loop condition.");

        Expr increment = null;
        if (!check(TokenType.RIGHT_PAREN)) {
            increment = expression();
        }
        consume(TokenType.RIGHT_PAREN, "Expect ')' after for clauses.");

        Stmt bod = matchStatement();

        if (increment !is null) {
            bod = new Block([bod, new Expression(increment)]);
        }
        if (condition is null) {
            condition = new Literal(Variant(true));
        }

        bod = new While(condition, bod);
        if (initializer !is null) {
            bod = new Block([initializer, bod]);
        }

        return bod;
    }

    private Stmt ifStatement() {
        consume(TokenType.LEFT_PAREN, "Expect '(' after 'if'.");
        Expr condition = expression();
        consume(TokenType.RIGHT_PAREN, "Expect ')' after if condition."); 

        Stmt thenBranch = matchStatement();
        Stmt elseBranch = null;

        if (match(TokenType.ELSE)) {
            elseBranch = matchStatement();
        }

        return statement!(If)(condition, thenBranch, elseBranch);
    }

    private Stmt whileStatement() {
        consume(TokenType.LEFT_PAREN, "Expect '(' after 'while'.");
        Expr condition = expression();
        consume(TokenType.RIGHT_PAREN, "Expect ')' after condition.");
        Stmt bod = matchStatement();

        return statement!(While)(condition, bod);
    }

    private Stmt[] block() {
        Stmt[] statements;

        while(!check(TokenType.RIGHT_BRACE) && !isAtEnd()) {
            statements ~= declaration();
        }

        consume(TokenType.RIGHT_BRACE, "Expect '}' after block.");
        return statements;
    }

    private T statement(T, A...)(A a) {
        if (!isAtEnd()
                && !match(TokenType.SEMICOLON)
                && !check(TokenType.RIGHT_BRACE)
                && previous().type != TokenType.SEMICOLON
                && previous().type != TokenType.RIGHT_BRACE)
            error(previous(), "Expect ';' after value.");
        return new T(a);
    }

    private Expr expression() {
        return separator();
    }

    private Expr separator() {
        with (TokenType) return rule!(Binary)(&assignment, COMMA);
    }

    private Expr assignment() {
        Expr expr = ternary();
        if (match(TokenType.EQUAL)) {
            TokenI equals = previous();
            Expr value = assignment();

            if (auto variable = cast(Variable) expr) {
                return new Assign(variable.name, value);
            }

            if (auto variable = cast(Get) expr) {
                return new Set(variable.object, variable.name, value);
            }

            error(equals, "Invalid assignment target.");
        }
        return expr;
    }

    private Expr ternary() {
        Expr expr = or();

        if (match(TokenType.QUERY)) {
            TokenI operator = previous();

            Expr middle = expression();

            consume(TokenType.COLON, "':' expected");

            expr = new Ternary(expr, operator, middle, ternary);
        }

        return expr;
    }

    private Expr or() {
        with (TokenType) return rule!(Logical)(&and, OR);
    }

    private Expr and() {
        with (TokenType) return rule!(Logical)(&equality, AND);
    }

    private Expr equality() {
        with (TokenType) return rule!(Binary)(&comparison, BANG_EQUAL, EQUAL_EQUAL);
    }

    private Expr comparison() {
        with (TokenType) return rule!(Binary)(&term, GREATER, GREATER_EQUAL, LESS, LESS_EQUAL);
    }

    private Expr term() {
        with (TokenType) return rule!(Binary)(&factor, MINUS, PLUS);
    }

    private Expr factor() {
        with (TokenType) return rule!(Binary)(&unary, SLASH, STAR);
    }

    private Expr unary() {
        with (TokenType) if (match(BANG, MINUS, AST)) {
            TokenI operator = previous();
            Expr right = unary();
            if (operator.type == AST) {
                if(Grouping gr = cast(Grouping)right) {
                    right = gr.expression;
                }
            }
            return new Unary(operator, right);
        }
        return call();
    }

    private Expr call() {
        Expr expr = funExpr();

        while (true) { 
            if (match(TokenType.LEFT_PAREN)) {
                expr = finishCall(expr);
            } else if (match(TokenType.DOT)) {
                TokenI name = consume(TokenType.IDENTIFIER,
                    "Expect property name after '.'.");
                expr = new Get(expr, name);
            } else {
                break;
            }
        }

        return expr;
    }

    private Expr funExpr() {
        if (match(TokenType.FUN)) {
            return fun();
        }
        return classExpr();
    }

    private Expr classExpr() {
        if (match(TokenType.CLASS)) {
            return _class();
        }
        return primary();
    }

    private Expr finishCall(Expr callee) {
        Expr[] arguments = [];

        if (!check(TokenType.RIGHT_PAREN)) {
            do {
                if (arguments.length >= 255) {
                    error(peek(), "Can't have more than 255 arguments.");
                }
                arguments ~= assignment();
            } while (match(TokenType.COMMA));
        }

        TokenI paren = consume(TokenType.RIGHT_PAREN, "Expect ')' after arguments.");

        return new Call(callee, paren, arguments);
    }

    private Expr primary() {
        with (TokenType) {
            if (match(FALSE))
                return new Literal(Variant(false));
            if (match(TRUE))
                return new Literal(Variant(true));
            if (match(NIL))
                return new Literal(Variant(null));
            if (match(IDENTIFIER))
                return new Variable(previous());
            if (match(NUMBER, STRING))
                return new Literal(previous().literal);
            if (match(THIS))
                return new This(previous());
            if (match(SUPER))
                return new Super(previous());

            if (match(LEFT_PAREN)) {
                Expr expr = expression();
                consume(RIGHT_PAREN, "Expect ')' after expression.");
                return new Grouping(expr);
            }
        }

        throw error(peek(), "Expression expected");
    }

    private Expr rule(T)(Expr delegate() rule, TokenType[] types ...) {
        Expr expr = rule();

        while (match(types)) {
            TokenI operator = previous();
            Expr right = rule();
            expr = new T(expr, operator, right);
        }
        return expr;
    }

    private TokenI consume(TokenType type, string message) {
        if (check(type)) return advance();

        throw error(peek(), message);
    }

    private ParseError error(TokenI token, string message) {
        Lox.error(token, message);
        return new ParseError(message);
    }

    private void synchronize() {
        advance();

        with (TokenType) while (!isAtEnd()) {
            if (previous().type == SEMICOLON) return;

            switch (peek().type) {
                case CLASS:
                case FUN:
                case VAR:
                case FOR:
                case IF:
                case WHILE:
                case PRINT:
                case RETURN:
                    return;
                default: break;
            }

            advance();
        }
    }

    private bool match(TokenType[] types ...) {
        foreach (type; types) {
            if (check(type)) {
                advance();
                return true;
            }
        }
        return false;
    }
    private bool check(TokenType type) {
        if (isAtEnd()) return false;
        return peek().type == type;
    }
    private TokenI advance() {
        if (!isAtEnd()) current++;
        return previous();
    }
    private bool isAtEnd() {
        return peek().type == TokenType.EOF;
    }

    private TokenI peek() {
        return tokens[current];
    }
    
    private TokenI peekNext() {
        return tokens[current + 1];
    }

    private TokenI previous() {
        return tokens[current - 1];
    }
}
