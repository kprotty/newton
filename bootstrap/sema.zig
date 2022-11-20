const std = @import("std");

const ast = @import("ast.zig");
const ir = @import("ir.zig");
const indexed_list = @import("indexed_list.zig");

pub const TypeIndex = indexed_list.Indices(u32, opaque{}, .{
    .void = .{.void = {}},
    .bool = .{.bool = {}},
    .type = .{.type = {}},
    .undefined = .{.undefined = {}},
    .comptime_int = .{.comptime_int = {}},
});
pub const ValueIndex = indexed_list.Indices(u32, opaque{}, .{
    .void = .{.type_idx = .void},
    .bool = .{.type_idx = .bool},
    .type = .{.type_idx = .type},
    .undefined = .{.undefined = {}},
    .discard_underscore = .{.discard_underscore = {}},
});
pub const DeclIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const StructFieldIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const StructIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const ScopeIndex = indexed_list.Indices(u32, opaque{}, .{
    .builtin_scope = .{
        .outer_scope = .none,
        .first_decl = .none,
    },
});
pub const StatementIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const ExpressionIndex = indexed_list.Indices(u32, opaque{}, .{});

const TypeList = indexed_list.IndexedList(TypeIndex, Type);
const ValueList = indexed_list.IndexedList(ValueIndex, Value);
const DeclList = indexed_list.IndexedList(DeclIndex, Decl);
const StructFieldList = indexed_list.IndexedList(StructFieldIndex, StructField);
const StructList = indexed_list.IndexedList(StructIndex, Struct);
const ScopeList = indexed_list.IndexedList(ScopeIndex, Scope);
const StatementList = indexed_list.IndexedList(StatementIndex, Statement);
const ExpressionList = indexed_list.IndexedList(ExpressionIndex, Expression);

fn canFitNumber(value: i65, requested_type: TypeIndex.Index) bool {
    switch(types.get(requested_type).*) {
        .comptime_int => return true,
        .unsigned_int => |bits| {
            if(value < 0) return false;
            if(value > std.math.pow(u65, 2, bits) - 1) return false;
            return true;
        },
        .signed_int => |bits| {
            if(value < -std.math.pow(i65, 2, bits - 1)) return false;
            if(value > std.math.pow(u65, 2, bits - 1) - 1) return false;
            return true;
        },
        else => return false,
    }
}

fn promoteInteger(value: i65, value_out: ValueIndex.OptIndex, requested_type: TypeIndex.Index) !ValueIndex.Index {
    if(!canFitNumber(value, requested_type)) return error.CannotPromote;

    switch(types.get(requested_type).*) {
        .comptime_int => return putValueIn(value_out, .{.comptime_int = value}),
        .unsigned_int => |bits| return putValueIn(value_out, .{.unsigned_int = .{.bits = bits, .value = value}}),
        .signed_int => |bits| return putValueIn(value_out, .{.signed_int = .{.bits = bits, .value = value}}),
        else => return error.CannotPromote,
    }
}

fn promoteToBiggest(lhs_idx: *ValueIndex.Index, rhs_idx: *ValueIndex.Index) !void {
    const lhs = values.get(lhs_idx.*);
    const rhs = values.get(rhs_idx.*);

    if(lhs.* == .comptime_int) {
        lhs_idx.* = try promoteInteger(lhs.comptime_int, .none, try rhs.getType());
        return;
    }
    if(rhs.* == .comptime_int) {
        rhs_idx.* = try promoteInteger(rhs.comptime_int, .none, try lhs.getType());
        return;
    }
}

fn analyzeStatementChain(
    parent_scope_idx: ScopeIndex.Index,
    first_ast_stmt: ast.StmtIndex.OptIndex,
    current_function: ValueIndex.OptIndex,
    current_break_block: StatementIndex.OptIndex,
) !Block {
    const block_scope_idx = try scopes.insert(.{.outer_scope = ScopeIndex.toOpt(parent_scope_idx)});
    const block_scope = scopes.get(block_scope_idx);
    var decl_builder = decls.builder();
    var stmt_builder = statements.builder();
    var curr_ast_stmt = first_ast_stmt;
    var reaches_end = true;
    while(ast.statements.getOpt(curr_ast_stmt)) |ast_stmt| {
        if(!reaches_end) {
            return error.StatementUnreachable;
        }
        switch(ast_stmt.value) {
            .declaration => |decl| {
                const init_value = try astDeclToValue(block_scope_idx, ast.ExprIndex.toOpt(decl.init_value), decl.type);
                try values.get(init_value).analyze();
                const new_decl = try decl_builder.insert(.{
                    .mutable = decl.mutable,
                    .static = false,
                    .stack_offset = null,
                    .function_param_idx = null,
                    .name = decl.identifier,
                    .init_value = init_value,
                    .next = .none,
                });
                _ = try stmt_builder.insert(.{.value = .{.declaration = new_decl}});
                if(block_scope.first_decl == .none) block_scope.first_decl = decl_builder.first;
            },
            .block_statement => |blk| {
                const new_scope = try scopes.insert(.{.outer_scope = ScopeIndex.toOpt(block_scope_idx)});
                const block = try analyzeStatementChain(new_scope, blk.first_child, current_function, current_break_block);
                _ = try stmt_builder.insert(.{.value = .{.block = block}});
            },
            .expression_statement => |ast_expr| {
                const value = try evaluateWithoutTypeHint(block_scope_idx, .none, ast_expr.expr);
                const expr = try expressions.insert(.{.value = value});
                _ = try stmt_builder.insert(.{.value = .{.expression = expr}});
            },
            .if_statement => |if_stmt| {
                const condition = try evaluateWithTypeHint(block_scope_idx, .none, if_stmt.condition, .bool);

                const taken_scope = try scopes.insert(.{
                    .outer_scope = ScopeIndex.toOpt(block_scope_idx),
                });
                const not_taken_scope = try scopes.insert(.{
                    .outer_scope = ScopeIndex.toOpt(block_scope_idx),
                });
                const taken_block = try analyzeStatementChain(taken_scope, if_stmt.first_taken, current_function, current_break_block);
                const not_taken_block = try analyzeStatementChain(not_taken_scope, if_stmt.first_not_taken, current_function, current_break_block);
                _ = try stmt_builder.insert(.{.value = .{.if_statement = .{
                    .condition = condition,
                    .taken = taken_block,
                    .not_taken = not_taken_block,
                }}});
                reaches_end = taken_block.reaches_end or not_taken_block.reaches_end;
            },
            .loop_statement => |loop| {
                std.debug.assert(loop.condition == .none);
                const body_scope = try scopes.insert(.{
                    .outer_scope = ScopeIndex.toOpt(block_scope_idx),
                });
                const loop_stmt_idx = try stmt_builder.insert(.{.value = .{.loop_statement = .{.body = undefined, .breaks = false}}});
                const body = try analyzeStatementChain(body_scope, loop.first_child, current_function, StatementIndex.toOpt(loop_stmt_idx));
                const loop_stmt = statements.get(loop_stmt_idx);
                loop_stmt.value.loop_statement.body = body;
                reaches_end = loop_stmt.value.loop_statement.breaks;
            },
            .break_statement => {
                if(StatementIndex.unwrap(current_break_block)) |break_block| {
                    reaches_end = false;
                    statements.get(break_block).value.loop_statement.breaks = true;
                    _ = try stmt_builder.insert(.{.value = .{.break_statement = break_block}});
                } else {
                    return error.BreakOutsideLoop;
                }
            },
            .return_statement => |ret_stmt| {
                const func_idx = ValueIndex.unwrap(current_function).?;
                const func = values.get(func_idx).function;
                const return_type = values.get(func.return_type);
                var expr = ValueIndex.OptIndex.none;
                if(ast.ExprIndex.unwrap(ret_stmt.expr)) |ret_expr| {
                    expr = ValueIndex.toOpt(try evaluateWithTypeHint(block_scope_idx, .none, ret_expr, return_type.type_idx));
                } else {
                    std.debug.assert(func.return_type == .void);
                }
                reaches_end = false;
                _ = try stmt_builder.insert(.{.value = .{.return_statement = .{.function = func_idx, .value = expr}}});
            },
            else => |stmt| std.debug.panic("TODO: Sema {s} statement", .{@tagName(stmt)}),
        }
        curr_ast_stmt = ast_stmt.next;
    }
    return .{.scope = block_scope_idx, .first_stmt = stmt_builder.first, .reaches_end = reaches_end};
}

fn putValueIn(
    value_out: ValueIndex.OptIndex,
    value: Value,
) !ValueIndex.Index {
    const retval = ValueIndex.unwrap(value_out) orelse try values.insert(undefined);
    values.get(retval).* = value;
    return retval;
}

fn evaluateWithoutTypeHint(
    scope_idx: ScopeIndex.Index,
    value_out: ValueIndex.OptIndex,
    expr_idx: ast.ExprIndex.Index,
) anyerror!ValueIndex.Index {
    switch(ast.expressions.get(expr_idx).*) {
        .void => return putValueIn(value_out, .{.type_idx = .void}),
        .anyopaque => return putValueIn(value_out, .{.type_idx = try types.addDedupLinear(.{.anyopaque = {}})}),
        .bool => return putValueIn(value_out, .{.type_idx = .bool}),
        .type => return putValueIn(value_out, .{.type_idx = .type}),
        .unsigned_int => |bits| return putValueIn(value_out, .{.type_idx = try types.addDedupLinear(.{.unsigned_int = bits})}),
        .signed_int => |bits| return putValueIn(value_out, .{.type_idx = try types.addDedupLinear(.{.signed_int = bits})}),
        .function_expression => |func_idx| {
            const func = ast.functions.get(func_idx);
            const param_scope_idx = try scopes.insert(.{.outer_scope = ScopeIndex.toOpt(scope_idx)});
            const param_scope = scopes.get(param_scope_idx);
            var param_builder = decls.builder();
            var curr_ast_param = func.first_param;
            var function_param_idx: u8 = 0;
            while(ast.function_params.getOpt(curr_ast_param)) |ast_param| {
                const param_type = try evaluateWithTypeHint(param_scope_idx, .none, ast_param.type, .type);
                _ = try param_builder.insert(.{
                    .mutable = true,
                    .static = false,
                    .stack_offset = null,
                    .function_param_idx = function_param_idx,
                    .name = ast_param.identifier,
                    .init_value = try values.addDedupLinear(.{.runtime = .{.expr = .none, .value_type = param_type}}),
                    .next = .none,
                });
                function_param_idx += 1;
                curr_ast_param = ast_param.next;
            }

            param_scope.first_decl = param_builder.first;

            const retval = try putValueIn(value_out, .{.function = .{
                .param_scope = param_scope_idx,
                .body = undefined,
                .return_type = try evaluateWithTypeHint(param_scope_idx, .none, func.return_type, .type),
            }});

            values.get(retval).function.body = try analyzeStatementChain(param_scope_idx, func.body, ValueIndex.toOpt(retval), .none);
            return retval;
        },
        .pointer_type => |ptr| {
            const item_type_idx = try values.insert(.{.unresolved = .{
                .expression = ptr.item,
                .requested_type = .type,
                .scope = scope_idx,
            }});
            try values.get(item_type_idx).analyze();
            return putValueIn(value_out, .{.type_idx = try types.insert(.{.pointer = .{
                .is_const = ptr.is_const,
                .is_volatile = ptr.is_volatile,
                .item = item_type_idx,
            }})});
        },
        .struct_expression => |type_body| {
            const struct_scope = try scopes.insert(.{.outer_scope = ScopeIndex.toOpt(scope_idx)});
            var decl_builder = decls.builder();
            var field_builder = struct_fields.builder();
            var curr_decl = type_body.first_decl;
            while(ast.statements.getOpt(curr_decl)) |decl| {
                switch(decl.value) {
                    .declaration => |inner_decl| {
                        _ = try decl_builder.insert(.{
                            .mutable = inner_decl.mutable,
                            .static = true,
                            .stack_offset = null,
                            .function_param_idx = null,
                            .name = inner_decl.identifier,
                            .init_value = try astDeclToValue(
                                struct_scope,
                                ast.ExprIndex.toOpt(inner_decl.init_value),
                                inner_decl.type,
                            ),
                            .next = .none,
                        });
                    },
                    .field_decl => |field_decl| {
                        std.debug.assert(field_decl.type != .none);
                        _ = try field_builder.insert(.{
                            .name = field_decl.identifier,
                            .init_value = try astDeclToValue(struct_scope, field_decl.init_value, field_decl.type),
                            .next = .none,
                        });
                    },
                    else => unreachable,
                }

                curr_decl = decl.next;
            }

            const struct_idx = try structs.insert(.{
                .first_field = field_builder.first,
                .scope = struct_scope,
            });

            scopes.get(struct_scope).first_decl = decl_builder.first;

            return putValueIn(value_out, .{
                .type_idx = try types.insert(.{ .struct_idx = struct_idx }),
            });
        },
        .identifier => |ident| {
            const scope = scopes.get(scope_idx);
            const token = try ident.retokenize();
            defer token.deinit();
            if(try scope.lookupDecl(token.identifier_value())) |decl| {
                const init_value = values.get(decl.init_value);
                try init_value.analyze();
                if(init_value.* != .runtime and !decl.mutable) {
                    return decl.init_value;
                }
                return putValueIn(value_out, .{.decl_ref = decls.getIndex(decl)});
            }
            return error.IdentifierNotFound;
        },
        .int_literal => |lit| {
            const tok = try lit.retokenize();
            return putValueIn(value_out, .{.comptime_int = tok.int_literal.value});
        },
        .char_literal => |lit| {
            const tok = try lit.retokenize();
            return putValueIn(value_out, .{.comptime_int = tok.char_literal.value});
        },
        .bool_literal => |lit| {
            return putValueIn(value_out, .{.bool = lit});
        },
        .undefined => return putValueIn(value_out, .{.undefined = {}}),
        .function_call => |call| {
            const callee_idx = try evaluateWithoutTypeHint(scope_idx, .none, call.callee);
            const callee = values.get(callee_idx);
            if(callee.* != .function) {
                return error.CallOnNonFunctionValue;
            }
            var arg_builder = expressions.builderWithPath("function_arg.next");
            var curr_ast_arg = call.first_arg;
            var curr_param_decl = scopes.get(callee.function.param_scope).first_decl;
            while(ast.expressions.getOpt(curr_ast_arg)) |ast_arg| {
                const func_arg = ast_arg.function_argument;
                const curr_param = decls.getOpt(curr_param_decl) orelse return error.TooManyArguments;
                _ = try arg_builder.insert(.{.function_arg = .{
                    .value = try evaluateWithTypeHint(
                        scope_idx,
                        .none,
                        func_arg.value,
                        values.get(values.get(curr_param.init_value).runtime.value_type).type_idx,
                    ),
                    .next = .none,
                }});
                curr_ast_arg = func_arg.next;
                curr_param_decl = curr_param.next;
            }
            if(curr_param_decl != .none) return error.NotEnoughArguments;
            return putValueIn(value_out, .{.runtime = .{
                .expr = ExpressionIndex.toOpt(try expressions.insert(.{.function_call = .{
                    .callee = callee_idx,
                    .first_arg = arg_builder.first,
                }})),
                .value_type = callee.function.return_type,
            }});
        },
        .parenthesized => |uop| return evaluateWithoutTypeHint(scope_idx, .none, uop.operand),
        .discard_underscore => return .discard_underscore,
        inline
        .plus, .plus_eq, .plus_mod, .plus_mod_eq,
        .minus, .minus_eq, .minus_mod, .minus_mod_eq,
        .multiply, .multiply_eq, .multiply_mod, .multiply_mod_eq,
        .divide, .divide_eq, .modulus, .modulus_eq,
        .shift_left, .shift_left_eq, .shift_right, .shift_right_eq,
        .bitand, .bitand_eq, .bitor, .bitxor_eq, .bitxor, .bitor_eq,
        .less, .less_equal, .greater, .greater_equal,
        .equals, .not_equal, .logical_and, .logical_or,
        .assign, .range,
        => |bop, tag| {
            var lhs = try evaluateWithoutTypeHint(scope_idx, .none, bop.lhs);
            var rhs = try evaluateWithoutTypeHint(scope_idx, .none, bop.rhs);
            const value_type = switch(tag) {
                .multiply_eq, .multiply_mod_eq, .divide_eq, .modulus_eq, .plus_eq, .plus_mod_eq, .minus_eq,
                .minus_mod_eq, .shift_left_eq, .shift_right_eq, .bitand_eq, .bitxor_eq, .bitor_eq, .assign,
                => .void,
                .less, .less_equal, .greater, .greater_equal,
                .equals, .not_equal, .logical_and, .logical_or,
                => .bool,
                .multiply, .multiply_mod, .divide, .modulus, .plus, .plus_mod,
                .minus, .minus_mod, .shift_left, .shift_right, .bitand, .bitor, .bitxor,
                => blk: {
                    try promoteToBiggest(&lhs, &rhs);
                    break :blk try values.addDedupLinear(.{.type_idx = try values.get(lhs).getType()});
                },
                else => std.debug.panic("TODO: {s}", .{@tagName(tag)}),
            };
            const sema_tag = switch(tag) {
                inline .plus, .plus_eq, .plus_mod, .plus_mod_eq => |a| "add" ++ @tagName(a)[4..],
                inline .minus, .minus_eq, .minus_mod, .minus_mod_eq => |a| "sub" ++ @tagName(a)[5..],
                inline .bitand, .bitand_eq, .bitor, .bitxor_eq, .bitxor, .bitor_eq => |a| "bit_" ++ @tagName(a)[3..],
                else => |a| @tagName(a),
            };

            return putValueIn(value_out, .{.runtime = .{
                .expr = ExpressionIndex.toOpt(try expressions.insert(
                    @unionInit(Expression, sema_tag, .{.lhs = lhs, .rhs = rhs}),
                )),
                .value_type = value_type,
            }});
        },
        .addr_of => |uop| {
            const operand_idx = try evaluateWithoutTypeHint(scope_idx, .none, uop.operand);
            const operand = values.get(operand_idx);
            const result_type = switch(operand.*) {
                .decl_ref => |decl_idx| blk: {
                    const decl = decls.get(decl_idx);
                    decl.stack_offset = @as(u32, undefined);
                    break :blk try values.addDedupLinear(.{
                        .type_idx = try types.addDedupLinear(.{.pointer = .{
                            .is_const = !decl.mutable,
                            .is_volatile = false,
                            .item = try values.addDedupLinear(.{.type_idx = try operand.getType()}),
                        }}),
                    });
                },
                .runtime => |_| @panic(":("),
                else => std.debug.panic("Can't take the addr of {s}", .{@tagName(operand.*)}),
            };

            return putValueIn(value_out, .{.runtime = .{
                .expr = ExpressionIndex.toOpt(try expressions.insert(.{.addr_of = operand_idx})),
                .value_type = result_type,
            }});
        },
        .deref => |uop| {
            const operand_idx = try evaluateWithoutTypeHint(scope_idx, .none, uop.operand);
            const operand = values.get(operand_idx);
            const operand_type = types.get(try operand.getType());
            std.debug.assert(operand_type.* == .pointer);
            return putValueIn(value_out, .{.deref = operand_idx});
        },
        .member_access => |bop| {
            var lhs = try evaluateWithoutTypeHint(scope_idx, .none, bop.lhs);
            const lhs_value = values.get(lhs);
            const rhs_expr = ast.expressions.get(bop.rhs);
            std.debug.assert(lhs_value.* == .decl_ref);
            std.debug.assert(rhs_expr.* == .identifier);
            const lhs_type = types.get(try lhs_value.getType());
            std.debug.assert(lhs_type.* == .struct_idx);
            const lhs_struct = structs.get(lhs_type.struct_idx);
            const token = try rhs_expr.identifier.retokenize();
            defer token.deinit();
            if(try lhs_struct.lookupField(token.identifier_value())) |field| {
                return putValueIn(value_out, .{.runtime = .{
                    .expr = .none, // TODO: Member access expression
                    .value_type = try values.addDedupLinear(.{
                        .type_idx = try values.get(field.init_value).getType(),
                    }),
                }});
            } else {
                return error.MemberNotFound;
            }
        },
        .array_subscript => |bop| {
            const rhs_idx = try evaluateWithoutTypeHint(scope_idx, .none, bop.rhs);
            const rhs = values.get(rhs_idx);
            const rhs_type = types.get(try rhs.getType());
            std.debug.assert(rhs_type.* == .signed_int or rhs_type.* == .unsigned_int or rhs_type.* == .comptime_int);
            const lhs_idx = try evaluateWithoutTypeHint(scope_idx, .none, bop.lhs);
            const lhs = values.get(lhs_idx);
            const lhs_type = types.get(try lhs.getType());
            std.debug.assert(lhs_type.* == .pointer);
            const size_expr = try values.addDedupLinear(.{.unsigned_int = .{
                .bits = 64,
                .value = @as(i65, @intCast(i64, types.get(values.get(lhs_type.pointer.item).type_idx).getSize()))
            }});
            const u64_type = try values.addDedupLinear(.{.type_idx = try types.addDedupLinear(.{.unsigned_int = 64})});
            const offset_expr = try values.insert(.{.runtime = .{
                .expr = ExpressionIndex.toOpt(try expressions.insert(.{.multiply = .{.lhs = rhs_idx, .rhs = size_expr}})),
                .value_type = u64_type,
            }});
            const ptr_expr = try values.insert(.{.runtime = .{
                .expr = ExpressionIndex.toOpt(try expressions.insert(.{.add = .{.lhs = lhs_idx, .rhs = offset_expr}})),
                .value_type = u64_type,
            }});
            return putValueIn(value_out, .{.deref = ptr_expr});
        },
        else => |expr| std.debug.panic("TODO: Sema {s} expression", .{@tagName(expr)}),
    }
}

fn evaluateWithTypeHint(
    scope_idx: ScopeIndex.Index,
    value_out: ValueIndex.OptIndex,
    expr_idx: ast.ExprIndex.Index,
    requested_type: TypeIndex.Index,
) !ValueIndex.Index {
    const evaluated_idx = try evaluateWithoutTypeHint(scope_idx, value_out, expr_idx);
    const evaluated = values.get(evaluated_idx);
    switch(evaluated.*) {
        .comptime_int => |value| return promoteInteger(value, value_out, requested_type),
        .unsigned_int, .signed_int => |int| return promoteInteger(int.value, value_out, requested_type),
        .bool => if(requested_type == .bool) return evaluated_idx,
        .type_idx => if(requested_type == .type) return evaluated_idx,
        .undefined => return values.addDedupLinear(.{.runtime = .{
            .expr = ExpressionIndex.toOpt(try expressions.addDedupLinear(.{.value = .undefined})),
            .value_type = try values.addDedupLinear(.{.type_idx = requested_type}),
        }}),
        .runtime => |rt| {
            if(values.get(rt.value_type).type_idx == requested_type) return evaluated_idx;
            const evaluated_type = types.get(try evaluated.getType());
            if(evaluated_type.* == .reference and values.get(evaluated_type.reference.item).type_idx == requested_type) {
                return values.addDedupLinear(.{.deref = evaluated_idx});
            }
        },
        .decl_ref => |dr| {
            const decl_type = try values.get(decls.get(dr).init_value).getType();
            if(decl_type == requested_type) return evaluated_idx;
        },
        .deref => if(values.get(types.get(try evaluated.getType()).reference.item).type_idx == requested_type) return evaluated_idx,
        else => {},
    }

    std.debug.panic("Could not evaluate {any} with type {any}", .{evaluated, types.get(requested_type)});
}

const Unresolved = struct {
    analysis_started: bool = false,
    expression: ast.ExprIndex.Index,
    requested_type: ValueIndex.OptIndex,
    scope: ScopeIndex.Index,

    pub fn evaluate(self: *@This(), value_out: ValueIndex.Index) !ValueIndex.Index {
        if(self.analysis_started) {
            return error.CircularReference;
        }

        self.analysis_started = true;
        if(values.getOpt(self.requested_type)) |request| {
            try request.analyze();
            return evaluateWithTypeHint(self.scope, ValueIndex.toOpt(value_out), self.expression, request.type_idx);
        } else {
            return evaluateWithoutTypeHint(self.scope, ValueIndex.toOpt(value_out), self.expression);
        }
    }
};

const SizedInt = struct {
    bits: u32,
    value: i65,
};

const PointerType = struct {
    is_const: bool,
    is_volatile: bool,
    item: ValueIndex.Index,
};

pub const Type = union(enum) {
    void,
    anyopaque,
    undefined,
    bool,
    type,
    comptime_int,
    unsigned_int: u32,
    signed_int: u32,
    struct_idx: StructIndex.Index,
    pointer: PointerType,
    reference: PointerType,

    pub fn getSize(self: @This()) u32 {
        return switch(self) {
            .void, .undefined, .comptime_int, .type => 0,
            .bool => 1,
            .unsigned_int, .signed_int => |int| @as(u32, 1) << @intCast(u5, std.math.log2_int_ceil(u32, @divTrunc(int + 7, 8))),
            .pointer, .reference => 8, // TODO: Platform specific pointer sizes
            else => |other| std.debug.panic("TODO: Get size of {s}", .{@tagName(other)}),
        };
    }
};

pub const RuntimeValue = struct {
    expr: ExpressionIndex.OptIndex,
    value_type: ValueIndex.Index,
};

pub const Value = union(enum) {
    unresolved: Unresolved,

    decl_ref: DeclIndex.Index,
    deref: ValueIndex.Index,

    // Values of type `type`
    type_idx: TypeIndex.Index,

    // Non-type comptile time known values
    void,
    undefined,
    bool: bool,
    comptime_int: i65,
    unsigned_int: SizedInt,
    signed_int: SizedInt,
    function: Function,
    discard_underscore,

    // Runtime known values
    runtime: RuntimeValue,

    pub fn analyze(self: *@This()) anyerror!void {
        switch(self.*) {
            .unresolved => |*u| self.* = values.get(try u.evaluate(values.getIndex(self))).*,
            .runtime => |r| try values.get(r.value_type).analyze(),
            else => {},
        }
    }

    pub fn getType(self: *@This()) !TypeIndex.Index {
        try self.analyze();
        return switch(self.*) {
            .unresolved => unreachable,
            .type_idx => .type,
            .void => .void,
            .undefined => .undefined,
            .bool => .bool,
            .comptime_int => .comptime_int,
            .unsigned_int => |int| try types.addDedupLinear(.{.unsigned_int = int.bits}),
            .signed_int => |int| try types.addDedupLinear(.{.signed_int = int.bits}),
            .runtime => |rt| values.get(rt.value_type).type_idx,
            .decl_ref => |dr| return values.get(decls.get(dr).init_value).getType(),
            .deref => |val| {
                const target = values.get(val);
                const target_type = types.get(try target.getType());
                return types.addDedupLinear(.{.reference = target_type.pointer});
            },
            else => |other| std.debug.panic("TODO: Get type of {s}", .{@tagName(other)}),
        };
    }
};

pub const Decl = struct {
    mutable: bool,
    static: bool,
    stack_offset: ?u32,
    function_param_idx: ?u8,
    name: ast.SourceRef,
    init_value: ValueIndex.Index,
    next: DeclIndex.OptIndex,

    pub fn analyze(self: *@This()) !void {
        const value_ptr = values.get(self.init_value);
        try value_ptr.analyze();
    }
};

pub const StructField = struct {
    name: ast.SourceRef,
    init_value: ValueIndex.Index,
    next: StructFieldIndex.OptIndex,
};

fn genericChainLookup(
    comptime IndexType: type,
    comptime NodeType: type,
    container: *indexed_list.IndexedList(IndexType, NodeType),
    list_head: IndexType.OptIndex,
    name: []const u8,
) !?*NodeType {
    var current = list_head;
    while(container.getOpt(current)) |node| {
        const token = try node.name.retokenize();
        defer token.deinit();
        if (std.mem.eql(u8, name, token.identifier_value())) {
            return node;
        }
        current = node.next;
    }
    return null;
}

pub const Struct = struct {
    first_field: StructFieldIndex.OptIndex,
    scope: ScopeIndex.Index,

    pub fn lookupField(self: *@This(), name: []const u8) !?*StructField {
        return genericChainLookup(StructFieldIndex, StructField, &struct_fields, self.first_field, name);
    }
};

pub const Function = struct {
    return_type: ValueIndex.Index,
    param_scope: ScopeIndex.Index,
    body: Block,
};

pub const Scope = struct {
    outer_scope: ScopeIndex.OptIndex,
    first_decl: DeclIndex.OptIndex = .none,

    pub fn lookupDecl(self: *@This(), name: []const u8) !?*Decl {
        var scope_idx = ScopeIndex.toOpt(scopes.getIndex(self));
        while(scopes.getOpt(scope_idx)) |scope| {
            if(try genericChainLookup(DeclIndex, Decl, &decls, scope.first_decl, name)) |result| {
                return result;
            }
            scope_idx = scope.outer_scope;
        }
        return null;
    }
};

pub const Block = struct {
    scope: ScopeIndex.Index,
    first_stmt: StatementIndex.OptIndex,
    reaches_end: bool,
};

pub const Statement = struct {
    next: StatementIndex.OptIndex = .none,
    ir_block: ir.BlockIndex.OptIndex = .none,
    value: union(enum) {
        expression: ExpressionIndex.Index,
        declaration: DeclIndex.Index,
        if_statement: struct {
            condition: ValueIndex.Index,
            taken: Block,
            not_taken: Block,
        },
        loop_statement: struct {
            body: Block,
            breaks: bool,
        },
        break_statement: StatementIndex.Index,
        return_statement: struct {
            function: ValueIndex.Index,
            value: ValueIndex.OptIndex,
        },
        block: Block,
    },
};

pub const BinaryOp = struct {
    lhs: ValueIndex.Index,
    rhs: ValueIndex.Index,
};

pub const FunctionArgument = struct {
    value: ValueIndex.Index,
    next: ExpressionIndex.OptIndex,
};

pub const FunctionCall = struct {
    callee: ValueIndex.Index,
    first_arg: ExpressionIndex.OptIndex,
};

pub const Expression = union(enum) {
    value: ValueIndex.Index,

    addr_of: ValueIndex.Index,
    // deref: ValueIndex.Index,

    add: BinaryOp,
    add_eq: BinaryOp,
    add_mod: BinaryOp,
    add_mod_eq: BinaryOp,
    sub: BinaryOp,
    sub_eq: BinaryOp,
    sub_mod: BinaryOp,
    sub_mod_eq: BinaryOp,
    multiply: BinaryOp,
    multiply_eq: BinaryOp,
    multiply_mod: BinaryOp,
    multiply_mod_eq: BinaryOp,
    divide: BinaryOp,
    divide_eq: BinaryOp,
    modulus: BinaryOp,
    modulus_eq: BinaryOp,
    shift_left: BinaryOp,
    shift_left_eq: BinaryOp,
    shift_right: BinaryOp,
    shift_right_eq: BinaryOp,
    bit_and: BinaryOp,
    bit_and_eq: BinaryOp,
    bit_or: BinaryOp,
    bit_or_eq: BinaryOp,
    bit_xor: BinaryOp,
    bit_xor_eq: BinaryOp,
    less: BinaryOp,
    less_equal: BinaryOp,
    greater: BinaryOp,
    greater_equal: BinaryOp,
    equals: BinaryOp,
    not_equal: BinaryOp,
    logical_and: BinaryOp,
    logical_or: BinaryOp,
    assign: BinaryOp,
    range: BinaryOp,

    function_arg: FunctionArgument,
    function_call: FunctionCall,
};

pub var types: TypeList = undefined;
pub var values: ValueList = undefined;
pub var decls: DeclList = undefined;
pub var struct_fields: StructFieldList = undefined;
pub var structs: StructList = undefined;
pub var scopes: ScopeList = undefined;
pub var statements: StatementList = undefined;
pub var expressions: ExpressionList = undefined;

pub fn init() !void {
    types = try TypeList.init(std.heap.page_allocator);
    values = try ValueList.init(std.heap.page_allocator);
    decls = try DeclList.init(std.heap.page_allocator);
    struct_fields = try StructFieldList.init(std.heap.page_allocator);
    structs = try StructList.init(std.heap.page_allocator);
    scopes = try ScopeList.init(std.heap.page_allocator);
    statements = try StatementList.init(std.heap.page_allocator);
    expressions = try ExpressionList.init(std.heap.page_allocator);
}

fn astDeclToValue(
    scope_idx: ScopeIndex.Index,
    value_idx: ast.ExprIndex.OptIndex,
    value_type_idx: ast.ExprIndex.OptIndex,
) !ValueIndex.Index {
    const value_type = if(ast.ExprIndex.unwrap(value_type_idx)) |value_type| blk: {
        break :blk ValueIndex.toOpt(try values.insert(.{.unresolved = .{
            .expression = value_type,
            .requested_type = .type,
            .scope = scope_idx,
        }}));
    } else .none;

    if(ast.ExprIndex.unwrap(value_idx)) |value| {
        return values.insert(.{.unresolved = .{
            .expression = value,
            .requested_type = value_type,
            .scope = scope_idx,
        }});
    } else {
        return values.insert(.{.runtime = .{.expr = .none, .value_type = ValueIndex.unwrap(value_type).?}});
    }
}
