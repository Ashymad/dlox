import token;
import error;
import std.variant;
import fun;
import interpreter;
import std.range;
import std.algorithm;
import std.stdio;

class Instance {
    private Variant[string] fields;
    private Fun constructor;

    this(Variant[string] fields = null) {
        this.fields = fields;
        this.constructor = null;
    }

    this(Instance inst) {
        this(inst.fields.dup);
    }

    Variant get(TokenI name) {
        if (auto field = name.lexeme in fields) {
            return *field;
        }
        throw new RuntimeError(name,
                "Undefined property '" ~ name.lexeme ~ "'.");
    }

    void set(TokenI name, Variant value) {
        fields[name.lexeme] = value;
    }

    void toString(scope void delegate(const(char)[]) sink) const {
        sink("<class instance>");
    }

    void addFields(Variant[string] newf) {
        foreach(name, value; newf.byPair) {
            fields.require(name, value);
        }
    }

    void updateFields(Variant[string] newf) {
        foreach(name, value; newf.byPair) {
            fields[name] = value;
        }
    }

    Variant[string] getFields() {
        return fields;
    }

    void bindMethods(string token, Instance instance = null) {
        foreach(name, field; fields.byPair) {
            if (field.convertsTo!(Fun)) {
                auto ifun = field.get!(Fun).bind(token,
                        instance ? instance : this);
                if (name == "init") {
                    ifun.setInitializer();
                    constructor = ifun;
                }
                fields[name] = Variant(ifun);
            }
        }
    }

    void construct(Variant[] arguments, Interpreter interpreter) {
        if(constructor) constructor.call(interpreter, arguments);
    }
}
