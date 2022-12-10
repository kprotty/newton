const std = @import("std");

const backends = @import("backends/backends.zig");
const indexed_list = @import("indexed_list.zig");
const sema = @import("sema.zig");
const rega = @import("rega.zig");

pub const DeclIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const BlockIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const BlockEdgeIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const PhiOperandIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const FunctionArgumentIndex = indexed_list.Indices(u32, opaque{}, .{});

// Based on
// "Simple and Efficient Construction of Static Single Assignment Form"
// https://pp.info.uni-karlsruhe.de/uploads/publikationen/braun13cc.pdf
// by
// Matthias Braun, Sebastian Buchwald, Sebastian Hack, Roland Leißa, Christoph Mallon and Andreas Zwinkau

pub const Bop = struct {
    lhs: DeclIndex.Index,
    rhs: DeclIndex.Index,
};

pub const VariableConstantBop = struct {
    lhs: DeclIndex.Index,
    rhs: u64,
};

pub const InstrType = enum {
    u8,
    u16,
    u32,
    u64,
};

const MemoryReference = struct {
    pointer_value: DeclIndex.Index,
    sema_pointer_type: sema.PointerType,

    fn instrType(self: @This()) InstrType {
        return typeFor(self.sema_pointer_type.item);
    }

    pub fn load(self: @This()) DeclInstr {
        std.debug.assert(!self.sema_pointer_type.is_volatile); // Not yet implemented
        return .{.load = .{.source = self.pointer_value, .type = self.instrType()}};
    }

    pub fn store(self: @This(), value: DeclIndex.Index) DeclInstr {
        std.debug.assert(!self.sema_pointer_type.is_volatile); // Not yet implemented
        std.debug.assert(!self.sema_pointer_type.is_const);
        return .{.store = .{.dest = self.pointer_value, .value = value}};
    }
};

fn typeForBits(bits: u32) InstrType {
    if(bits <= 8) return .u8;
    if(bits <= 16) return .u16;
    if(bits <= 32) return .u32;
    if(bits <= 64) return .u64;
    @panic("it's too big for me :pensive:");
}

fn typeFor(type_idx: sema.TypeIndex.Index) InstrType {
    return switch(sema.types.get(type_idx).*) {
        .signed_int, .unsigned_int => |bits| typeForBits(bits),
        .reference, .pointer, .void => backends.current_backend.pointer_type,
        else => |other| std.debug.panic("TODO: typeFor {s}", .{@tagName(other)}),
    };
}

const Cast = struct {
    value: DeclIndex.Index,
    type: InstrType,
};

const FunctionArgument = struct {
    value: DeclIndex.Index,
    next: FunctionArgumentIndex.OptIndex = .none,
};

const DeclInstr = union(enum) {
    param_ref: struct {
        param_idx: u8,
        type: InstrType,
    },
    stack_ref: struct { offset: u32, type: sema.PointerType },
    offset_ref: struct { offset: u32, type: sema.PointerType },
    load_int_constant: struct {
        value: u64,
        type: InstrType,
    },
    clobber: DeclIndex.Index,
    addr_of: DeclIndex.Index,
    zero_extend: Cast,
    sign_extend: Cast,
    truncate: Cast,
    load_bool_constant: bool,
    enter_function: u32,
    leave_function: struct {
        restore_stack: bool,
        value: DeclIndex.Index,
    },
    undefined,

    function_call: struct {
        callee: sema.ValueIndex.Index,
        first_argument: FunctionArgumentIndex.OptIndex,
    },
    syscall: FunctionArgumentIndex.OptIndex,

    add: Bop,
    add_mod: Bop,
    sub: Bop,
    sub_mod: Bop,
    multiply: Bop,
    multiply_mod: Bop,
    divide: Bop,
    modulus: Bop,
    shift_left: Bop,
    shift_right: Bop,
    bit_and: Bop,
    bit_or: Bop,
    bit_xor: Bop,
    less: Bop,
    less_equal: Bop,
    equals: Bop,
    not_equal: Bop,

    store: struct {
        dest: DeclIndex.Index,
        value: DeclIndex.Index,
    },
    store_constant: struct {
        dest: DeclIndex.Index,
        type: InstrType,
        value: u64,
    },
    load: struct {
        source: DeclIndex.Index,
        type: InstrType,
    },
    reference_wrap: MemoryReference,

    add_constant: VariableConstantBop,
    add_mod_constant: VariableConstantBop,
    sub_constant: VariableConstantBop,
    sub_mod_constant: VariableConstantBop,
    multiply_constant: VariableConstantBop,
    multiply_mod_constant: VariableConstantBop,
    divide_constant: VariableConstantBop,
    modulus_constant: VariableConstantBop,
    shift_left_constant: VariableConstantBop,
    shift_right_constant: VariableConstantBop,
    bit_and_constant: VariableConstantBop,
    bit_or_constant: VariableConstantBop,
    bit_xor_constant: VariableConstantBop,

    less_constant: VariableConstantBop,
    less_equal_constant: VariableConstantBop,
    greater_constant: VariableConstantBop,
    greater_equal_constant: VariableConstantBop,
    equals_constant: VariableConstantBop,
    not_equal_constant: VariableConstantBop,

    incomplete_phi: DeclIndex.OptIndex, // Holds the next incomplete phi node in the same block
    copy: DeclIndex.Index, // Should be eliminated during optimization
    @"if": struct {
        condition: DeclIndex.Index,
        taken: BlockEdgeIndex.Index,
        not_taken: BlockEdgeIndex.Index,
    },
    goto: BlockEdgeIndex.Index,
    phi: PhiOperandIndex.OptIndex,

    const OperandIterator = struct {
        value: union(enum) {
            bounded_iterator: std.BoundedArray(*DeclIndex.Index, 2),
            arg_iterator: ?*FunctionArgument,
            phi_iterator: ?*PhiOperand,
        },

        pub fn next(self: *@This()) ?*DeclIndex.Index {
            switch(self.value) {
                .bounded_iterator => |*list| return list.popOrNull(),
                .phi_iterator => |*curr_opt| {
                    if(curr_opt.*) |curr| {
                        curr_opt.* = phi_operands.getOpt(curr.next);
                        return &curr.decl;
                    } else {
                        return null;
                    }
                },
                .arg_iterator => |*curr_opt| {
                    if(curr_opt.*) |curr| {
                        curr_opt.* = function_arguments.getOpt(curr.next);
                        return &curr.value;
                    } else {
                        return null;
                    }
                }
            }
        }
    };

    pub fn operands(self: *@This()) OperandIterator {
        var bounded_result = OperandIterator{.value = .{.bounded_iterator = .{}}};

        switch(self.*) {
            .incomplete_phi => unreachable,

            .phi => |p| return .{.value = .{.phi_iterator = phi_operands.getOpt(p)}},
            .function_call => |fcall| return .{.value = .{.arg_iterator = function_arguments.getOpt(fcall.first_argument)}},
            .syscall => |farg| return .{.value = .{.arg_iterator = function_arguments.getOpt(farg)}},

            .add, .add_mod, .sub, .sub_mod,
            .multiply, .multiply_mod, .divide, .modulus,
            .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
            .less, .less_equal, .equals, .not_equal,
            => |*bop| {
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&bop.lhs);
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&bop.rhs);
            },

            .reference_wrap => |*rr| {
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&rr.pointer_value);
            },

            .zero_extend, .sign_extend, .truncate => |*cast| bounded_result.value.bounded_iterator.appendAssumeCapacity(&cast.value),
            .clobber, .addr_of => |*op| bounded_result.value.bounded_iterator.appendAssumeCapacity(op),

            .add_constant, .add_mod_constant, .sub_constant, .sub_mod_constant,
            .multiply_constant, .multiply_mod_constant, .divide_constant, .modulus_constant,
            .shift_left_constant, .shift_right_constant, .bit_and_constant, .bit_or_constant, .bit_xor_constant,
            .less_constant, .less_equal_constant, .greater_constant, .greater_equal_constant,
            .equals_constant, .not_equal_constant,
            => |*bop| {
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&bop.lhs);
            },

            .store => |*p| {
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&p.dest);
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&p.value);
            },
            .store_constant => |*p| bounded_result.value.bounded_iterator.appendAssumeCapacity(&p.dest),

            .copy => |*c| bounded_result.value.bounded_iterator.appendAssumeCapacity(c),
            .load => |*p| bounded_result.value.bounded_iterator.appendAssumeCapacity(&p.source),
            .@"if" => |*instr| bounded_result.value.bounded_iterator.appendAssumeCapacity(&instr.condition),
            .leave_function => |*value| bounded_result.value.bounded_iterator.appendAssumeCapacity(&value.value),

            .param_ref, .stack_ref, .offset_ref,
            .load_int_constant, .load_bool_constant,
            .undefined, .goto, .enter_function,
            => {}, // No operands
        }

        return bounded_result;
    }

    pub fn memoryReference(self: *const @This()) ?MemoryReference {
        const self_index = decls.getIndex(@fieldParentPtr(Decl, "instr", self));
        switch(self.*) {
            .stack_ref => |sr| return .{
                .pointer_value = self_index,
                .sema_pointer_type = sr.type,
            },
            .offset_ref => |offref| return .{
                .pointer_value = self_index,
                .sema_pointer_type = offref.type,
            },
            .reference_wrap => |rr| return rr,
            else => return null,
        }
    }

    pub fn isVolatile(self: *const @This()) bool {
        switch(self.*) {
            .incomplete_phi => unreachable,
            .@"if", .leave_function, .goto, .enter_function, .store, .store_constant, .function_call, .syscall,
            => return true,
            else => return false,
        }
    }

    pub fn isValue(self: *const @This()) bool {
        switch(self.*) {
            .incomplete_phi => unreachable,
            .@"if", .leave_function, .goto, .stack_ref, .offset_ref, .enter_function,
            .store, .store_constant, .reference_wrap,
            => return false,
            else => return true,
        }
    }

    pub fn isFlagsValue(self: *const @This()) bool {
        switch(self.*) {
            .less, .less_equal, .equals, .not_equal,
            .less_constant, .less_equal_constant, .greater_constant,
            .greater_equal_constant, .equals_constant, .not_equal_constant,
            => return true,
            else => return false,
        }
    }

    pub fn outEdges(self: *@This()) std.BoundedArray(*BlockEdgeIndex.Index, 2) {
        var result = std.BoundedArray(*BlockEdgeIndex.Index, 2){};
        switch(self.*) {
            .incomplete_phi => unreachable,
            .@"if" => |*instr| {
                result.appendAssumeCapacity(&instr.taken);
                result.appendAssumeCapacity(&instr.not_taken);
            },
            .goto => |*out| result.appendAssumeCapacity(out),
            else => {}, // No out edges
        }
        return result;
    }

    pub fn getOperationType(self: *const @This()) InstrType {
        switch(self.*) {
            inline
            .param_ref, .load_int_constant, .load, .store_constant,
            .zero_extend, .sign_extend, .truncate,
            => |cast| return cast.type,
            .clobber => return .u64,
            .addr_of, .stack_ref, .offset_ref,
            => return backends.current_backend.pointer_type,
            .reference_wrap => |rr| return rr.instrType(),
            .add, .add_mod, .sub, .sub_mod,
            .multiply, .multiply_mod, .divide, .modulus,
            .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
            .less, .less_equal, .equals, .not_equal,
            => |bop| {
                const lhs = decls.get(bop.lhs);
                const lhs_type = lhs.instr.getOperationType();
                const rhs = decls.get(bop.rhs);
                const rhs_type = rhs.instr.getOperationType();
                std.debug.assert(lhs_type == rhs_type);
                return lhs_type;
            },
            .function_call => |fcall| {
                const rt = sema.values.get(fcall.callee).function.return_type;
                return typeFor(sema.values.get(rt).type_idx);
            },
            .syscall, .undefined => return .u64,
            .store => |val| return decls.get(val.value).instr.getOperationType(),
            .add_constant, .add_mod_constant, .sub_constant, .sub_mod_constant,
            .multiply_constant, .multiply_mod_constant, .divide_constant, .modulus_constant,
            .shift_left_constant, .shift_right_constant, .bit_and_constant, .bit_or_constant, .bit_xor_constant,
            .less_constant, .less_equal_constant, .greater_constant, .greater_equal_constant, .equals_constant, .not_equal_constant,
            => |bop| return decls.get(bop.lhs).instr.getOperationType(),
            .copy => |decl| return decls.get(decl).instr.getOperationType(),
            .phi => |phi_operand| {
                // TODO:
                // Block#1:
                //   ...
                //   u64 $5 = 0
                //   ...
                // Block#3:
                //   u64 $8 = phi([$5, Block#1], [$19, Block#7])
                //   ...
                // Block#7:
                //   u64 $19 = add($8, #1)
                //   ...
                var curr_operand = phi_operand;
                // var first_type: InstrType = undefined;
                // var first_iter = true;
                while(phi_operands.getOpt(curr_operand)) |operand| : (curr_operand = operand.next) {
                    const operand_type = decls.get(operand.decl).instr.getOperationType();
                    return operand_type;
                    // if(first_iter) {
                    //     first_type = operand_type;
                    // } else if() {
                    //     std.debug.assert(operand_type == first_type);
                    // }
                }
                // std.debug.assert(!first_iter);
                // return first_type;
                return undefined;
            },
            else => |other| std.debug.panic("TODO getOperationType of {s}", .{@tagName(other)}),
        }
    }
};

pub const Decl = struct {
    next: DeclIndex.OptIndex = .none,
    prev: DeclIndex.OptIndex = .none,
    block: BlockIndex.Index,

    sema_decl: sema.DeclIndex.OptIndex,
    instr: DeclInstr,
    reg_alloc_value: ?u8 = null,
};

const InstructionToBlockEdge = struct {
    source_block: BlockIndex.Index,
    target_block: BlockIndex.Index,
    next: BlockEdgeIndex.OptIndex,
};

const PhiOperand = struct {
    edge: BlockEdgeIndex.Index,
    decl: DeclIndex.Index,
    next: PhiOperandIndex.OptIndex = .none,
};

pub const BasicBlock = struct {
    is_sealed: bool = false,
    is_filled: bool = false,
    first_incomplete_phi_node: DeclIndex.OptIndex = .none,
    first_predecessor: BlockEdgeIndex.OptIndex = .none,
    first_decl: DeclIndex.OptIndex = .none,
    last_decl: DeclIndex.OptIndex = .none,

    pub fn seal(self: *@This()) !void {
        while(decls.getOpt(self.first_incomplete_phi_node)) |decl| {
            self.first_incomplete_phi_node = decl.instr.incomplete_phi;
            _ = try addPhiOperands(
                sema.DeclIndex.unwrap(decl.sema_decl).?,
                blocks.getIndex(self),
                decls.getIndex(decl),
                false,
            );
        }
        self.is_sealed = true;
    }

    pub fn filled(self: *@This()) !void {
        self.is_filled = true;
    }
};

// Name from paper
fn readVariable(block_idx: BlockIndex.Index, decl: sema.DeclIndex.Index) anyerror!DeclIndex.Index {
    const odecl = sema.DeclIndex.toOpt(decl);
    // Look backwards to find value in current basic block
    var pred_idx = blocks.get(block_idx).last_decl;
    while(decls.getOpt(pred_idx)) |pred| {
        if(pred.sema_decl == odecl) return decls.getIndex(pred);
        pred_idx = pred.prev;
    }
    return readVariableRecursive(block_idx, decl);
}

// Name from paper
fn readVariableRecursive(block_idx: BlockIndex.Index, decl: sema.DeclIndex.Index) !DeclIndex.Index {
    const odecl = sema.DeclIndex.toOpt(decl);
    const block = blocks.get(block_idx);
    if(!block.is_sealed) {
        const new_phi = try appendToBlock(block_idx, .{
            .incomplete_phi = block.first_incomplete_phi_node,
        });
        decls.get(new_phi).sema_decl = odecl;
        block.first_incomplete_phi_node = DeclIndex.toOpt(new_phi);
        return new_phi;
    } else {
        const first_predecessor = block.first_predecessor;
        const first_edge = edges.getOpt(first_predecessor).?;

        if(edges.getOpt(first_edge.next)) |_| {
            // Block gets new phi node
            const new_phi = try appendToBlock(block_idx, .{
                .incomplete_phi = undefined,
            });
            decls.get(new_phi).sema_decl = odecl;
            return addPhiOperands(decl, block_idx, new_phi, true);
        } else {
            std.debug.assert(blocks.get(first_edge.source_block).is_filled);
            return readVariable(first_edge.source_block, decl);
        }
    }
}

// Name from paper
fn addPhiOperands(sema_decl: sema.DeclIndex.Index, block_idx: BlockIndex.Index, phi_idx: DeclIndex.Index, delete: bool) !DeclIndex.Index {
    const block = blocks.get(block_idx);
    var current_pred_edge = block.first_predecessor;
    var init_operand = PhiOperandIndex.OptIndex.none;

    while(edges.getOpt(current_pred_edge)) |edge| {
        const eidx = edges.getIndex(edge);

        const new_operand = try phi_operands.insert(.{
            .edge = eidx,
            .decl = try readVariable(edge.source_block, sema_decl),
            .next = init_operand,
        });

        init_operand = PhiOperandIndex.toOpt(new_operand);
        current_pred_edge = edge.next;
    }

    decls.get(phi_idx).instr = .{.phi = init_operand};
    return tryRemoveTrivialPhi(phi_idx, delete);
}

pub fn removeDecl(decl_idx: DeclIndex.Index) void {
    const decl = decls.get(decl_idx);
    const block = blocks.get(decl.block);

    if(decls.getOpt(decl.prev)) |prev| {
        prev.next = decl.next;
    } else {
        block.first_decl = decl.next;
    }
    if(decls.getOpt(decl.next)) |next| {
        next.prev = decl.prev;
    } else {
        block.last_decl = decl.prev;
    }
    decls.free(decl_idx);
}

/// Name from paper
fn tryRemoveTrivialPhi(phi_decl: DeclIndex.Index, delete: bool) DeclIndex.Index {
    if(checkTrivialPhi(phi_decl)) |trivial_decl| {
        if(trivial_decl) |trivial_idx| {
            if(delete) {
                removeDecl(phi_decl);
                return trivial_idx;
            } else {
                decls.get(phi_decl).instr = .{.copy = trivial_idx};
            }
        } else {
            // This is zero operand phi node. What does it meme?
            decls.get(phi_decl).instr = .{.undefined = {}};
        }
    }

    return phi_decl;
}

// Name from paper
fn checkTrivialPhi(phi_decl: DeclIndex.Index) ??DeclIndex.Index {
    var current_operand = decls.get(phi_decl).instr.phi;
    var only_decl: ?DeclIndex.Index = null;

    while(phi_operands.getOpt(current_operand)) |op| {
        if(only_decl) |only| {
            if(only != op.decl and op.decl != phi_decl) return null;
        } else {
            only_decl = op.decl;
        }
        current_operand = op.next;
    }

    return only_decl;
}

// Assumes an arena allocator is passed
const DiscoverContext = struct {
    to_visit: std.ArrayList(BlockIndex.Index),
    visited: std.AutoArrayHashMap(BlockIndex.Index, void),

    fn init(allocator: std.mem.Allocator, first_block: BlockIndex.Index) !@This() {
        var result: @This() = undefined;
        result.to_visit = std.ArrayList(BlockIndex.Index).init(allocator);
        try result.to_visit.append(first_block);
        result.visited = std.AutoArrayHashMap(BlockIndex.Index, void).init(allocator);
        try result.visited.put(first_block, {});
        return result;
    }

    fn nextBlock(self: *@This()) ?*BasicBlock {
        if(self.to_visit.items.len > 0) {
            return blocks.get(self.to_visit.swapRemove(0));
        } else {
            return null;
        }
    }

    fn edge(self: *@This(), eidx: BlockEdgeIndex.Index) !void {
        const target_idx = edges.get(eidx).target_block;
        if(self.visited.get(target_idx) == null) {
            try self.to_visit.append(target_idx);
            try self.visited.put(target_idx, {});
        }
    }

    fn finalize(self: *@This()) []BlockIndex.Index {
        return self.visited.keys();
    }
};

pub const BlockList = std.ArrayListUnmanaged(BlockIndex.Index);

// Assumes an arena allocator is passed
pub fn allBlocksReachableFrom(allocator: std.mem.Allocator, head_block: BlockIndex.Index) !BlockList {
    var context = try DiscoverContext.init(allocator, head_block);

    while(context.nextBlock()) |block| {
        var current_decl = block.first_decl;
        while(decls.getOpt(current_decl)) |decl| {
            const decl_block_edges = decl.instr.outEdges();
            for(decl_block_edges.slice()) |edge| {
                try context.edge(edge.*);
            }
            current_decl = decl.next;
        }
    }

    const elements = context.finalize();
    return BlockList{.items = elements, .capacity = elements.len};
}

const function_optimizations = .{
    eliminateCopies,
    eliminateUnreferenced,
    eliminateDeadBlocks,
    deduplicateDecls,
};

const peephole_optimizations = .{
    eliminateTrivialPhis,
    eliminateConstantIfs,
    eliminateRedundantIfs,
    eliminateIndirectBranches,
    inlineConstants,
    eliminateTrivialArithmetic,
    eliminateConstantExpressions,
};

var optimization_allocator = std.heap.GeneralPurposeAllocator(.{}){.backing_allocator = std.heap.page_allocator};

pub fn optimizeFunction(head_block: BlockIndex.Index) !void {
    var arena = std.heap.ArenaAllocator.init(optimization_allocator.allocator());
    defer arena.deinit();
    var fn_blocks = try allBlocksReachableFrom(arena.allocator(), head_block);

    while(true) {
        var did_something = false;
        for(fn_blocks.items) |block| {
            var current_decl = blocks.get(block).first_decl;
            while(decls.getOpt(current_decl)) |decl| {
                current_decl = decl.next;
                inline for(peephole_optimizations) |pass| {
                    if(try pass(decls.getIndex(decl))) did_something = true;
                }
            }
        }
        inline for(function_optimizations) |pass| {
            var pass_allocator = std.heap.ArenaAllocator.init(optimization_allocator.allocator());
            defer pass_allocator.deinit();
            if(try pass(pass_allocator.allocator(), &fn_blocks)) did_something = true;
        }
        if(!did_something) return;
    }
}

fn eliminateCopyChain(
    decl_idx: DeclIndex.Index,
    copy_dict: *std.AutoHashMap(DeclIndex.Index, DeclIndex.Index)
) !DeclIndex.Index {
    if(copy_dict.get(decl_idx)) |retval| { // Copy decl has already been removed
        return retval;
    }
    const decl = decls.get(decl_idx);
    if(decl.instr == .copy) {
        const retval = try eliminateCopyChain(decl.instr.copy, copy_dict);
        try copy_dict.put(decl_idx, retval);
        decl.instr = .{.undefined = {}};
        return retval;
    }
    return decl_idx;
}

fn eliminateCopyOperands(
    operand: *DeclIndex.Index,
    copy_dict: *std.AutoHashMap(DeclIndex.Index, DeclIndex.Index)
) !void {
    operand.* = try eliminateCopyChain(operand.*, copy_dict);
}

fn eliminateDeadBlocks(alloc: std.mem.Allocator, fn_blocks: *BlockList) !bool {
    const new_blocks = try allBlocksReachableFrom(alloc, fn_blocks.items[0]);
    if(new_blocks.items.len == fn_blocks.items.len) return false;
    std.mem.copy(BlockIndex.Index, fn_blocks.items, new_blocks.items);
    fn_blocks.shrinkRetainingCapacity(new_blocks.items.len);
    return true;
}

fn deduplicateDecls(alloc: std.mem.Allocator, fn_blocks: *BlockList) !bool {
    var decl_dict = std.AutoHashMap(DeclInstr, DeclIndex.Index).init(alloc);

    var did_something = false;
    for(fn_blocks.items) |block| {
        var current_decl = blocks.get(block).first_decl;
        while(decls.getOpt(current_decl)) |decl| : (current_decl = decl.next) {
            switch(decl.instr) {
                .stack_ref, .load_int_constant, .load_bool_constant, .undefined,
                .addr_of,

                .add, .add_mod, .sub, .sub_mod,
                .multiply, .multiply_mod, .divide, .modulus,
                .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
                .less, .less_equal, .equals, .not_equal,

                .add_constant, .add_mod_constant, .sub_constant, .sub_mod_constant,
                .multiply_constant, .multiply_mod_constant, .divide_constant, .modulus_constant,
                .shift_left_constant, .shift_right_constant,
                .bit_and_constant, .bit_or_constant, .bit_xor_constant,

                .less_constant, .less_equal_constant, .greater_constant, .greater_equal_constant,
                .equals_constant, .not_equal_constant,
                => {
                    const value = try decl_dict.getOrPut(decl.instr);
                    if(value.found_existing) {
                        decl.instr = .{.copy = value.value_ptr.*};
                        did_something = true;
                    } else {
                        value.value_ptr.* = decls.getIndex(decl);
                    }
                },
                else => {},
            }
        }
    }
    return did_something;
}

fn eliminateCopies(alloc: std.mem.Allocator, fn_blocks: *BlockList) !bool {
    var copy_dict = std.AutoHashMap(DeclIndex.Index, DeclIndex.Index).init(alloc);
    var did_something = false;

    for(fn_blocks.items) |block| {
        var current_decl = blocks.get(block).first_decl;
        while(decls.getOpt(current_decl)) |decl| {
            current_decl = decl.next;
            var ops = decl.instr.operands();
            while(ops.next()) |op| {
                try eliminateCopyOperands(op, &copy_dict);
            }
            if(decls.getIndex(decl) != try eliminateCopyChain(decls.getIndex(decl), &copy_dict)) {
                did_something = true;
            }
        }
    }

    return did_something;
}

fn eliminateUnreferenced(alloc: std.mem.Allocator, fn_blocks: *BlockList) !bool {
    var unreferenced = std.AutoHashMap(DeclIndex.Index, void).init(alloc);
    var referenced_undiscovered = std.AutoHashMap(DeclIndex.Index, void).init(alloc);

    for(fn_blocks.items) |block| {
        var current_decl = blocks.get(block).first_decl;
        while(decls.getOpt(current_decl)) |decl| {
            const idx = decls.getIndex(decl);
            current_decl = decl.next;
            if(!referenced_undiscovered.remove(idx) and !decl.instr.isVolatile()) {
                try unreferenced.put(idx, {});
            }

            var ops = decl.instr.operands();
            while(ops.next()) |op| {
                if(!unreferenced.remove(op.*)) {
                    try referenced_undiscovered.put(op.*, {});
                }
            }
        }
    }

    var it = unreferenced.keyIterator();
    var did_something = false;
    while(it.next()) |key| {
        removeDecl(key.*);
        did_something = true;
    }
    return did_something;
}

fn eliminateTrivialPhis(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    if(decl.instr == .phi) {
        _ = tryRemoveTrivialPhi(decl_idx, false);
        return decl.instr != .phi;
    }
    return false;
}

fn eliminateConstantIfs(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    if(decl.instr == .@"if") {
        const if_instr = decl.instr.@"if";
        const cond_decl = decls.get(if_instr.condition);

        switch(cond_decl.instr) {
            .load_bool_constant => |value| {
                decl.instr = .{.goto = if(value) if_instr.taken else if_instr.not_taken};
                return true;
            },
            else => {},
        }
    }
    return false;
}

fn eliminateRedundantIfs(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    if(decl.instr == .@"if") {
        const if_instr = decl.instr.@"if";
        const taken_edge = edges.get(if_instr.taken);
        const not_taken_edge = edges.get(if_instr.not_taken);
        if(taken_edge.target_block == not_taken_edge.target_block) {
            decl.instr = .{.goto = if_instr.taken};
            return true;
        }
    }
    return false;
}

fn eliminateIndirectBranches(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    var did_something = false;
    for(decl.instr.outEdges().slice()) |edge| {
        const target_edge = edges.get(edge.*);
        const target_block = blocks.get(target_edge.target_block);
        if(target_block.first_decl == target_block.last_decl) {
            const first_decl = decls.getOpt(target_block.first_decl) orelse continue;
            if(first_decl.instr == .goto) {
                const goto_edge = edges.get(first_decl.instr.goto);
                if(target_edge != goto_edge) {
                    goto_edge.source_block = decl.block;
                    edge.* = first_decl.instr.goto;
                    did_something = true;
                }
            }
        }
    }
    return did_something;
}

fn inlineConstants(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    switch(decl.instr) {
        // Commutative ops
        inline
        .add, .add_mod, .multiply, .multiply_mod,
        .bit_and, .bit_or, .bit_xor, .equals, .not_equal
        => |bop, tag| {
            const lhs = decls.get(bop.lhs).instr;
            if(lhs == .load_int_constant) {
                decl.instr = @unionInit(DeclInstr, @tagName(tag) ++ "_constant", .{
                    .lhs = bop.rhs,
                    .rhs = lhs.load_int_constant.value,
                });
                return true;
            }
            const rhs = decls.get(bop.rhs).instr;
            if(rhs == .load_int_constant) {
                decl.instr = @unionInit(DeclInstr, @tagName(tag) ++ "_constant", .{
                    .lhs = bop.lhs,
                    .rhs = rhs.load_int_constant.value,
                });
               return true;
            }
        },

        // Noncommutative ops
        inline
        .less, .less_equal, .sub, .sub_mod, .divide, .modulus,
        .shift_left, .shift_right,
        => |bop, tag| {
            const swapped_tag: ?[]const u8 = comptime switch(tag) {
                .less => "greater_equal",
                .less_equal => "greater",
                else => null,
            };

            const lhs = decls.get(bop.lhs).instr;
            if(swapped_tag != null and lhs == .load_int_constant) {
                decl.instr = @unionInit(DeclInstr, swapped_tag.? ++ "_constant", .{
                    .lhs = bop.rhs,
                    .rhs = lhs.load_int_constant.value,
                });
                return true;
            }

            const rhs = decls.get(bop.rhs).instr;
            if(rhs == .load_int_constant) {
                decl.instr = @unionInit(DeclInstr, @tagName(tag) ++ "_constant", .{
                    .lhs = bop.lhs,
                    .rhs = rhs.load_int_constant.value,
                });
               return true;
            }
        },

        .store => |store| {
            const value = decls.get(store.value).instr;
            if(value == .load_int_constant) {
                if(value.load_int_constant.value == 0 or backends.current_backend.optimizations.has_nonzero_constant_store) {
                    decl.instr = .{.store_constant = .{
                        .dest = store.dest,
                        .type = value.load_int_constant.type,
                        .value = value.load_int_constant.value,
                    }};
                    return true;
                }
            }
        },

        else => {},
    }
    return false;
}

fn eliminateTrivialArithmetic(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    switch(decl.instr) {
        .add, .add_mod => |bop| {
            if(bop.lhs == bop.rhs) {
                decl.instr = .{.multiply_constant = .{.lhs = bop.lhs, .rhs = 2}};
                return true;
            }
        },
        .bit_and, .bit_or => |bop| {
            if(bop.lhs == bop.rhs) {
                decl.instr = .{.copy = bop.lhs};
                return true;
            }
        },
        .bit_xor, .sub, .sub_mod => |bop| {
            if(bop.lhs == bop.rhs) {
                decl.instr = .{.load_int_constant = .{
                    .type = decl.instr.getOperationType(),
                    .value = 0,
                }};
                return true;
            }
        },
        .equals, .not_equal => |bop| {
            if(bop.lhs == bop.rhs) {
                decl.instr = .{.load_bool_constant = decl.instr == .equals};
                return true;
            }
        },

        inline
        .add_constant, .add_mod_constant, .sub_constant, .sub_mod_constant,
        .shift_left_constant, .shift_right_constant,
        => |*bop, tag| {
            if(bop.rhs == 0) {
                decl.instr = .{.copy = bop.lhs};
                return true;
            }
            const lhs_decl = decls.get(bop.lhs);
            if(std.meta.activeTag(lhs_decl.instr) == std.meta.activeTag(decl.instr)) {
                const lhs_instr = @field(lhs_decl.instr, @tagName(tag));
                bop.lhs = lhs_instr.lhs;
                bop.rhs +%= lhs_instr.rhs;
                return true;
            }
            // if(lhs_decl.instr == .stack_ref) {
            //     decl.instr = .{.stack_ref = lhs_decl.instr.stack_ref - @intCast(u32, bop.rhs)};
            //     return true;
            // }
        },
        .bit_or_constant, .bit_xor_constant,
        => |bop| {
            if(bop.rhs == 0) {
                decl.instr = .{.copy = bop.lhs};
                return true;
            }
        },
        .multiply_constant, .multiply_mod_constant,
        => |bop| {
            if(bop.rhs == 0) {
                decl.instr = .{.load_int_constant = .{
                    .type = decl.instr.getOperationType(),
                    .value = 0,
                }};
            } else if(bop.rhs == 1) {
                decl.instr = .{.copy = bop.lhs};
                return true;
            } else {
                const l2 = std.math.log2_int(u64, bop.rhs);
                if((@as(u64, 1) << l2) == bop.rhs) {
                    decl.instr = .{.shift_left_constant = .{.lhs = bop.lhs, .rhs = l2}};
                    return true;
                }
                const lhs_decl = decls.get(bop.lhs);
                switch(lhs_decl.instr) {
                    .multiply_constant => |op_bop| {
                        decl.instr.multiply_constant.lhs = op_bop.lhs;
                        decl.instr.multiply_constant.rhs *= op_bop.rhs;
                        return true;
                    },
                    else => {},
                }
            }
        },
        .divide_constant => |bop| {
            if(bop.rhs == 0) {
                decl.instr = .{.undefined = {}};
                return true;
            } else {
                const l2 = std.math.log2_int(u64, bop.rhs);
                if((@as(u64, 1) << l2) == bop.rhs) {
                    decl.instr = .{.shift_right_constant = .{.lhs = bop.lhs, .rhs = l2}};
                    return true;
                }
            }
        },
        .modulus_constant => |bop| {
            // TODO: check value against type size to optimize more
            if(bop.rhs == 0) {
                decl.instr = .{.undefined = {}};
                return true;
            } else {
                const l2 = std.math.log2_int(u64, bop.rhs);
                if((@as(u64, 1) << l2) == bop.rhs) {
                    decl.instr = .{.bit_and_constant = .{.lhs = bop.lhs, .rhs = bop.rhs - 1}};
                    return true;
                }
            }
        },
        .bit_and_constant => |bop| {
            // TODO: check value against type size to optimize more
            if(bop.rhs == 0) {
                decl.instr = .{.load_int_constant = .{
                    .type = decl.instr.getOperationType(),
                    .value = 0,
                }};
                return true;
            }
        },
        else => {},
    }

    return false;
}

fn eliminateConstantExpressions(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    switch(decl.instr) {
        .store => |store| {
            const value = decls.get(store.value);
            if(value.instr == .undefined) {
                decl.instr = .{.undefined = {}};
            }
        },
        inline
        .add_constant, .add_mod_constant, .sub_constant, .sub_mod_constant,
        .multiply_constant, .multiply_mod_constant, .divide_constant, .modulus_constant,
        .shift_left_constant, .shift_right_constant, .bit_and_constant, .bit_or_constant, .bit_xor_constant,
        => |bop, tag| {
            const lhs = decls.get(bop.lhs);
            if(lhs.instr == .load_int_constant) {
                decl.instr = .{.load_int_constant = .{
                    .value = switch(tag) {
                        .add_constant => lhs.instr.load_int_constant.value + bop.rhs,
                        .add_mod_constant => lhs.instr.load_int_constant.value +% bop.rhs,
                        .sub_constant => lhs.instr.load_int_constant.value - bop.rhs,
                        .sub_mod_constant => lhs.instr.load_int_constant.value -% bop.rhs,
                        .multiply_constant => lhs.instr.load_int_constant.value * bop.rhs,
                        .multiply_mod_constant => lhs.instr.load_int_constant.value *% bop.rhs,
                        .divide_constant => lhs.instr.load_int_constant.value / bop.rhs,
                        .modulus_constant => lhs.instr.load_int_constant.value % bop.rhs,
                        .shift_left_constant => lhs.instr.load_int_constant.value << @intCast(u6, bop.rhs),
                        .shift_right_constant => lhs.instr.load_int_constant.value >> @intCast(u6, bop.rhs),
                        .bit_and_constant => lhs.instr.load_int_constant.value & bop.rhs,
                        .bit_or_constant => lhs.instr.load_int_constant.value | bop.rhs,
                        .bit_xor_constant => lhs.instr.load_int_constant.value ^ bop.rhs,
                        else => unreachable,
                    },
                    .type = decl.instr.getOperationType(),
                }};
                return true;
            }
        },
        inline
        .less_constant, .less_equal_constant, .greater_constant, .greater_equal_constant,
        .equals_constant, .not_equal_constant,
        => |bop, tag| {
            const lhs = decls.get(bop.lhs);
            if(lhs.instr == .load_int_constant) {
                decl.instr = .{.load_bool_constant = switch(tag) {
                    .less_constant => lhs.instr.load_int_constant.value < bop.rhs,
                    .less_equal_constant => lhs.instr.load_int_constant.value <= bop.rhs,
                    .greater_constant => lhs.instr.load_int_constant.value > bop.rhs,
                    .greater_equal_constant => lhs.instr.load_int_constant.value >= bop.rhs,
                    .equals_constant => lhs.instr.load_int_constant.value == bop.rhs,
                    .not_equal_constant => lhs.instr.load_int_constant.value != bop.rhs,
                    else => unreachable,
                }};
                return true;
            }
        },
        else => {},
    }
    return false;
}

pub fn insertBefore(before: DeclIndex.Index, instr: DeclInstr) !DeclIndex.Index {
    const retval = blk: {
        const bdecl = decls.get(before);

        break :blk try decls.insert(.{
            .next = DeclIndex.toOpt(before),
            .prev = bdecl.prev,
            .block = bdecl.block,
            .instr = instr,
            .sema_decl = .none,
        });
    };

    const bdecl = decls.get(before);
    const blk_idx = bdecl.block;
    const blk = blocks.get(blk_idx);

    bdecl.prev = DeclIndex.toOpt(retval);

    if(blk.first_decl == DeclIndex.toOpt(before)) {
        blk.first_decl = DeclIndex.toOpt(retval);
    } else {
        decls.getOpt(decls.get(retval).prev).?.next = DeclIndex.toOpt(retval);
    }

    return retval;
}

fn appendToBlock(
    block_idx: BlockIndex.Index,
    instr: DeclInstr,
) !DeclIndex.Index {
    const block = blocks.get(block_idx);

    const retval = try decls.insert(.{
        .block = block_idx,
        .instr = instr,
        .sema_decl = .none,
    });
    const oretval = DeclIndex.toOpt(retval);

    if(decls.getOpt(block.last_decl)) |last| {
        last.next = oretval;
        decls.get(retval).prev = block.last_decl;
    }
    block.last_decl = oretval;

    if(block.first_decl == .none) {
        block.first_decl = oretval;
    }

    return retval;
}

fn addEdge(
    source_idx: BlockIndex.Index,
    target_idx: BlockIndex.Index,
) !BlockEdgeIndex.Index {
    const target_block = blocks.get(target_idx);

    std.debug.assert(!target_block.is_sealed);

    const retval = try edges.insert(.{
        .source_block = source_idx,
        .target_block = target_idx,
        .next = target_block.first_predecessor,
    });

    target_block.first_predecessor = BlockEdgeIndex.toOpt(retval);

    return retval;
}

fn ssaBlockStatementIntoBasicBlock(
    first_stmt: sema.StatementIndex.OptIndex,
    scope: sema.ScopeIndex.Index,
    basic_block: BlockIndex.Index,
    return_phi_node: DeclIndex.Index,
    stack_offset: u32,
    max_stack_usage: *u32,
) !BlockIndex.Index {
    _ = scope;
    var current_statement = first_stmt;
    var current_basic_block = basic_block;
    var current_stack_offset = stack_offset;

    defer max_stack_usage.* = std.math.max(max_stack_usage.*, current_stack_offset);
    while(sema.statements.getOpt(current_statement)) |stmt| : (current_statement = stmt.next) {
        switch(stmt.value) {
            .block => |b| {
                // A freestanding block statement is part of the same basic block but with a different scope
                // and TODO: a new break target location
                current_basic_block = try ssaBlockStatementIntoBasicBlock(
                    b.first_stmt,
                    b.scope,
                    current_basic_block,
                    return_phi_node,
                    current_stack_offset,
                    max_stack_usage,
                );
            },
            .declaration => |decl_idx| {
                const decl = sema.decls.get(decl_idx);
                const init_value = sema.values.get(decl.init_value);

                if(!decl.static) {
                    if(decl.offset) |*offset| {
                        const decl_type = sema.types.get(try init_value.getType());
                        const alignment = try decl_type.getAlignment();
                        current_stack_offset += alignment - 1;
                        current_stack_offset &= ~@as(u32, alignment - 1);
                        current_stack_offset += try decl_type.getSize();
                        offset.* = current_stack_offset;
                    }
                }

                const value = if(init_value.* == .runtime) blk: {
                    const expr = init_value.runtime.expr;
                    break :blk try ssaExpr(
                        current_basic_block,
                        sema.ExpressionIndex.unwrap(expr).?,
                    );
                } else blk: {
                    const val = sema.values.get(decl.init_value);
                    if(val.* == .function) continue;
                    break :blk try ssaValue(current_basic_block, decl.init_value);
                };
                decls.get(value).sema_decl = sema.DeclIndex.toOpt(decl_idx);

                if(!decl.static) {
                    if(decl.offset) |offset| {
                        const stack_ref = try appendToBlock(current_basic_block, .{.stack_ref = .{
                            .offset = offset,
                            .type = .{
                                .is_const = !decl.mutable,
                                .is_volatile = false,
                                .item = try sema.values.get(decl.init_value).getType(),
                            },
                        }});
                        _ = try appendToBlock(current_basic_block, .{.store = .{.dest = stack_ref, .value = value}});
                    }
                }
            },
            .expression => |expr_idx| {
                _ = try ssaExpr(current_basic_block, expr_idx);
            },
            .if_statement => |if_stmt| {
                const condition_value = try ssaValue(current_basic_block, if_stmt.condition);

                const if_branch = try appendToBlock(current_basic_block, .{.@"if" = .{
                    .condition = condition_value,
                    .taken = undefined,
                    .not_taken = undefined,
                }});
                try blocks.get(current_basic_block).filled();

                const taken_entry = try blocks.insert(.{});
                const not_taken_entry = try blocks.insert(.{});
                decls.get(if_branch).instr.@"if".taken = try addEdge(current_basic_block, taken_entry);
                try blocks.get(taken_entry).seal();
                decls.get(if_branch).instr.@"if".not_taken = try addEdge(current_basic_block, not_taken_entry);
                try blocks.get(not_taken_entry).seal();

                const if_exit = try blocks.insert(.{});
                const taken_exit = try ssaBlockStatementIntoBasicBlock(
                    if_stmt.taken.first_stmt,
                    if_stmt.taken.scope,
                    taken_entry,
                    return_phi_node,
                    current_stack_offset,
                    max_stack_usage,
                );
                if(if_stmt.taken.reaches_end) {
                    const taken_exit_branch = try appendToBlock(taken_exit, .{.goto = undefined});
                    decls.get(taken_exit_branch).instr.goto = try addEdge(taken_exit, if_exit);
                }
                try blocks.get(taken_exit).filled();

                const not_taken_exit = try ssaBlockStatementIntoBasicBlock(
                    if_stmt.not_taken.first_stmt,
                    if_stmt.not_taken.scope,
                    not_taken_entry,
                    return_phi_node,
                    current_stack_offset,
                    max_stack_usage,
                );
                if (if_stmt.not_taken.reaches_end) {
                    const not_taken_exit_branch = try appendToBlock(not_taken_exit, .{.goto = undefined});
                    decls.get(not_taken_exit_branch).instr.goto = try addEdge(not_taken_exit, if_exit);
                }
                try blocks.get(not_taken_exit).filled();

                try blocks.get(if_exit).seal();

                current_basic_block = if_exit;
            },
            .loop_statement => |loop| {
                const loop_enter_branch = try appendToBlock(current_basic_block, .{.goto = undefined});
                const loop_body_entry = try blocks.insert(.{});
                decls.get(loop_enter_branch).instr.goto = try addEdge(current_basic_block, loop_body_entry);
                try blocks.get(current_basic_block).filled();

                const exit_block = try blocks.insert(.{});
                stmt.ir_block = BlockIndex.toOpt(exit_block);
                const loop_body_end = try ssaBlockStatementIntoBasicBlock(
                    loop.body.first_stmt,
                    loop.body.scope,
                    loop_body_entry,
                    return_phi_node,
                    current_stack_offset,
                    max_stack_usage,
                );
                try blocks.get(exit_block).seal();
                if(loop.body.reaches_end) {
                    const loop_instr = try appendToBlock(loop_body_end, .{.goto = undefined});
                    decls.get(loop_instr).instr.goto = try addEdge(loop_body_end, loop_body_entry);
                }
                try blocks.get(loop_body_end).filled();
                try blocks.get(loop_body_entry).seal();

                current_basic_block = exit_block;
            },
            .break_statement => |break_block| {
                const goto_block = BlockIndex.unwrap(sema.statements.get(break_block).ir_block).?;
                _ = try appendToBlock(current_basic_block, .{.goto = try addEdge(current_basic_block, goto_block)});
            },
            .return_statement => |return_stmt| {
                var value = if(sema.ValueIndex.unwrap(return_stmt.value)) |sema_value| blk: {
                    break :blk try ssaValue(current_basic_block, sema_value);
                } else blk: {
                    break :blk try appendToBlock(current_basic_block, .{.undefined = {}});
                };

                const phi_decl = decls.get(return_phi_node);
                const exit_edge = try addEdge(current_basic_block, phi_decl.block);
                phi_decl.instr.phi = PhiOperandIndex.toOpt(try phi_operands.insert(.{
                    .edge = exit_edge,
                    .decl = value,
                    .next = phi_decl.instr.phi,
                }));

                _ = try appendToBlock(current_basic_block, .{.@"goto" = exit_edge});
            },
        }
    }
    return current_basic_block;
}

fn ssaValue(
    block_idx: BlockIndex.Index,
    value_idx: sema.ValueIndex.Index,
) !DeclIndex.Index {
    const value = sema.values.get(value_idx);
    switch(value.*) {
        .runtime => |rt| return ssaExpr(block_idx, sema.ExpressionIndex.unwrap(rt.expr).?),
        .decl_ref => |decl_idx| {
            const rdecl = sema.decls.get(decl_idx);
            const ref_t = sema.PointerType{
                .is_const = !rdecl.mutable,
                .is_volatile = false,
                .item = try sema.values.get(rdecl.init_value).getType(),
            };
            if(rdecl.static) {
                return appendToBlock(block_idx, .{.offset_ref = .{ .offset = rdecl.offset.?, .type = ref_t}});
            } else if(rdecl.offset) |offset| {
                return appendToBlock(block_idx, .{.stack_ref = .{ .offset = offset, .type = ref_t}});
            } else {
                return readVariable(block_idx, decl_idx);
            }
        },
        .comptime_int => |c| {
            return appendToBlock(block_idx, .{.load_int_constant = .{
                .value = @intCast(u64, c),
                .type = .u64, // TODO
            }});
        },
        .bool => |b| return appendToBlock(block_idx, .{.load_bool_constant = b}),
        .unsigned_int, .signed_int => |int| {
            // TODO: Pass value bit width along too
            return appendToBlock(block_idx, .{.load_int_constant = .{
                .value = @intCast(u64, int.value),
                .type = typeForBits(int.bits),
            }});
        },
        .undefined => return appendToBlock(block_idx, .{.undefined = {}}),
        else => |val| std.debug.panic("Unhandled ssaing of value {s}", .{@tagName(val)}),
    }
}

fn ssaExpr(block_idx: BlockIndex.Index, expr_idx: sema.ExpressionIndex.Index) anyerror!DeclIndex.Index {
    switch(sema.expressions.get(expr_idx).*) {
        .value => |val_idx| return ssaValue(block_idx, val_idx),
        .assign => |ass| {
            // Evaluate rhs first because it makes more lifetime sense for assignment ops
            const rhs = try ssaValue(block_idx, ass.rhs);
            const rhs_decl = decls.get(rhs);

            const rhs_value = if(rhs_decl.instr.memoryReference()) |mr|
                try appendToBlock(block_idx, mr.load()) else rhs;

            if(ass.lhs != .discard_underscore) {
                const lhs_sema = sema.values.get(ass.lhs);
                if(lhs_sema.* == .decl_ref) {
                    const rhs_value_decl = decls.get(rhs_value);
                    if(!sema.decls.get(lhs_sema.decl_ref).static) {
                        const new_rhs = try appendToBlock(block_idx, rhs_value_decl.instr);
                        decls.get(new_rhs).sema_decl = sema.DeclIndex.toOpt(lhs_sema.decl_ref);
                        return undefined;
                    }
                }
                const lhs = try ssaValue(block_idx, ass.lhs);
                const lhs_mr = decls.get(lhs).instr.memoryReference().?;
                _ = try appendToBlock(block_idx, lhs_mr.store(rhs_value));
            }
            return undefined;
        },
        inline
        .add, .add_mod, .sub, .sub_mod,
        .multiply, .multiply_mod, .divide, .modulus,
        .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
        .less, .less_equal, .equals, .not_equal,
        => |bop, tag| {
            return appendToBlock(block_idx, @unionInit(DeclInstr, @tagName(tag), .{
                .lhs = try ssaValue(block_idx, bop.lhs),
                .rhs = try ssaValue(block_idx, bop.rhs),
            }));
        },
        inline
        .add_eq, .add_mod_eq, .sub_eq, .sub_mod_eq,
        .multiply_eq, .multiply_mod_eq, .divide_eq, .modulus_eq,
        .shift_left_eq, .shift_right_eq, .bit_and_eq, .bit_or_eq, .bit_xor_eq,
        => |bop, tag| {
            _ = bop;
            _ = tag;
            @panic("TODO: IR Inplace ops");
            // const lhs_ref = try ssaValue(block_idx, bop.lhs);
            // const rhs_ref = try ssaValue(block_idx, bop.rhs);
            // const value = try appendToBlock(block_idx, @unionInit(DeclInstr, @tagName(tag)[0..@tagName(tag).len - 3], .{
            //     .lhs = lhs_ref,
            //     .rhs = rhs_ref,
            // }));
            // return ssaValue(block_idx, bop.lhs);
        },
        .greater => |bop| return appendToBlock(block_idx, .{.less_equal = .{
            .lhs = try ssaValue(block_idx, bop.rhs),
            .rhs = try ssaValue(block_idx, bop.lhs),
        }}),
        .greater_equal => |bop| return appendToBlock(block_idx, .{.less = .{
            .lhs = try ssaValue(block_idx, bop.rhs),
            .rhs = try ssaValue(block_idx, bop.lhs),
        }}),
        .addr_of => |operand| {
            return appendToBlock(block_idx, .{.addr_of = try ssaValue(block_idx, operand)});
        },
        .zero_extend => |cast| return appendToBlock(block_idx, .{.zero_extend = .{
            .value = try ssaValue(block_idx, cast.value),
            .type = typeFor(cast.type),
        }}),
        .sign_extend => |cast| return appendToBlock(block_idx, .{.sign_extend = .{
            .value = try ssaValue(block_idx, cast.value),
            .type = typeFor(cast.type),
        }}),
        .truncate => |cast| return appendToBlock(block_idx, .{.truncate = .{
            .value = try ssaValue(block_idx, cast.value),
            .type = typeFor(cast.type),
        }}),
        .function_call => |fcall| {
            var builder = function_arguments.builder();
            var curr_arg = fcall.first_arg;
            while(sema.expressions.getOpt(curr_arg)) |arg| : (curr_arg = arg.function_arg.next) {
                const farg = arg.function_arg;
                const value = try ssaValue(block_idx, farg.value);
                if(decls.get(value).instr.memoryReference()) |mr| {
                    _ = try builder.insert(.{.value = try appendToBlock(block_idx, mr.load())});
                } else {
                    _ = try builder.insert(.{.value = value });
                }
            }
            if(fcall.callee == .syscall_func) return appendToBlock(block_idx, .{.syscall = builder.first});
            return appendToBlock(block_idx, .{.function_call = .{
                .callee = fcall.callee,
                .first_argument = builder.first,
            }});
        },
        .offset => |offref| return appendToBlock(block_idx, .{.offset_ref = .{
            .offset = offref.offset,
            .type = offref.type,
        }}),
        .deref => |sidx| {
            const pointer_value = try ssaValue(block_idx, sidx);
            return appendToBlock(block_idx, .{.reference_wrap = .{
                .pointer_value = pointer_value,
                .sema_pointer_type = sema.types.get(try sema.values.get(sidx).getType()).pointer,
            }});
        },
        else => |expr| std.debug.panic("Unhandled ssaing of expr {s}", .{@tagName(expr)}),
    }
}

pub fn ssaFunction(func: *sema.Function) !BlockIndex.Index {
    const first_basic_block = try blocks.insert(.{});
    const enter_decl = try appendToBlock(first_basic_block, .{.enter_function = undefined});
    try blocks.get(first_basic_block).seal();

    // Loop over function params and add references to them
    var curr_param = sema.scopes.get(func.param_scope).first_decl;
    while(sema.decls.getOpt(curr_param)) |decl| {
        const param = try appendToBlock(first_basic_block, .{
            .param_ref = .{
                .param_idx = decl.function_param_idx.?,
                .type = typeFor(try sema.values.get(decl.init_value).getType()),
            },
        });
        decls.get(param).sema_decl = curr_param;

        curr_param = decl.next;
    }

    const exit_block = try blocks.insert(.{});
    const phi = try appendToBlock(exit_block, .{.phi = .none});
    const exit_return = try appendToBlock(exit_block, .{.leave_function = .{.restore_stack = false, .value = phi}});

    var stack_offset: u32 = 0;
    const return_block = try ssaBlockStatementIntoBasicBlock(
        func.body.first_stmt,
        func.body.scope,
        first_basic_block,
        phi,
        stack_offset,
        &stack_offset,
    );
    if(func.body.reaches_end) {
        _ = try appendToBlock(return_block, .{.goto = try addEdge(return_block, exit_block)});
    }

    decls.get(enter_decl).instr.enter_function = stack_offset;
    decls.get(exit_return).instr.leave_function.restore_stack = stack_offset > 0;
    return first_basic_block;
}

pub fn dumpBlock(
    bb: BlockIndex.Index,
    uf: ?rega.UnionFind,
) !void {
    std.debug.print("Block#{d}:\n", .{@enumToInt(bb)});
    var current_decl = blocks.get(bb).first_decl;
    while(decls.getOpt(current_decl)) |decl| : (current_decl = decl.next) {
        if(decl.instr == .clobber) continue;
        std.debug.print("  ", .{});
        std.debug.print("${d}", .{@enumToInt(current_decl)});
        const adecl = blk: { break :blk (uf orelse break :blk decl).findDeclByPtr(decl); };
        if(adecl != decl) {
            std.debug.print(" (-> ${d})", .{@enumToInt(decls.getIndex(adecl))});
        }
        if(adecl.reg_alloc_value) |reg| {
            std.debug.print(" ({s})", .{backends.current_backend.register_name(reg)});
        }
        std.debug.print(" = ", .{});
        if(decl.instr.isValue()) {
            std.debug.print("{s} ", .{@tagName(decl.instr.getOperationType())});
        }
        switch(decl.instr) {
            .param_ref => |p| std.debug.print("@param({d})\n", .{p.param_idx}),
            .stack_ref => |p| std.debug.print("@stack({d})\n", .{p.offset}),
            .offset_ref => |p| std.debug.print("@offset({d})\n", .{p.offset}),
            .addr_of => |p| std.debug.print("@addr_of(${d})\n", .{@enumToInt(p)}),
            .enter_function => |stack_size| std.debug.print("enter_function({d})\n", .{stack_size}),
            .leave_function => |leave| std.debug.print("leave_function(${d})\n", .{@enumToInt(leave.value)}),
            .load_int_constant => |value| std.debug.print("{d}\n", .{value.value}),
            .reference_wrap => |ref| std.debug.print("@deref(${d})\n", .{@enumToInt(ref.pointer_value)}),
            .zero_extend, .sign_extend, .truncate => |cast| std.debug.print("@{s}(${d})\n", .{@tagName(decl.instr), @enumToInt(cast.value)}),
            .load_bool_constant => |b| std.debug.print("{}\n", .{b}),
            .undefined => std.debug.print("undefined\n", .{}),
            .load => |p| std.debug.print("@load(${d})\n", .{@enumToInt(p.source)}),
            inline
            .add, .add_mod, .sub, .sub_mod,
            .multiply, .multiply_mod, .divide, .modulus,
            .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
            .less, .less_equal, .equals, .not_equal,
            => |bop, tag| std.debug.print("{s}(${d}, ${d})\n", .{@tagName(tag), @enumToInt(bop.lhs), @enumToInt(bop.rhs)}),
            inline
            .add_constant, .add_mod_constant, .sub_constant, .sub_mod_constant,
            .multiply_constant, .multiply_mod_constant, .divide_constant, .modulus_constant,
            .shift_left_constant, .shift_right_constant, .bit_and_constant, .bit_or_constant, .bit_xor_constant,
            .less_constant, .less_equal_constant, .greater_constant, .greater_equal_constant,
            .equals_constant, .not_equal_constant,
            => |bop, tag| std.debug.print("{s}(${d}, #{d})\n", .{@tagName(tag)[0..@tagName(tag).len-9], @enumToInt(bop.lhs), bop.rhs}),
            .function_call => {
                std.debug.print("@call(<?>", .{});
                var ops = decl.instr.operands();
                while(ops.next()) |op| {
                    std.debug.print(", ${d}", .{@enumToInt(op.*)});
                }
                std.debug.print(")\n", .{});
            },
            .syscall => {
                std.debug.print("@syscall(", .{});
                var first = true;
                var ops = decl.instr.operands();
                while(ops.next()) |op| {
                    if (!first) {
                        std.debug.print(", ", .{});
                    }
                    std.debug.print("${d}", .{@enumToInt(op.*)});
                    first = false;
                }
                std.debug.print(")\n", .{});
            },
            .store => |store| std.debug.print("store(${d}, ${d})\n", .{@enumToInt(store.dest), @enumToInt(store.value)}),
            .store_constant => |store| std.debug.print("store(${d}, #{d})\n", .{@enumToInt(store.dest), store.value}),
            .incomplete_phi => std.debug.print("<incomplete phi node>\n", .{}),
            .copy => |c| std.debug.print("@copy(${d})\n", .{@enumToInt(c)}),
            .@"if" => |if_instr| {
                std.debug.print("if(${d}, Block#{d}, Block#{d})\n", .{
                    @enumToInt(if_instr.condition),
                    @enumToInt(edges.get(if_instr.taken).target_block),
                    @enumToInt(edges.get(if_instr.not_taken).target_block),
                });
            },
            .goto => |goto_edge| {
                std.debug.print("goto(Block#{d})\n", .{@enumToInt(edges.get(goto_edge).target_block)});
            },
            .phi => |phi_index| {
                var current_phi = phi_index;
                std.debug.print("phi(", .{});
                while(phi_operands.getOpt(current_phi)) |phi| {
                    const edge = edges.get(phi.edge);
                    std.debug.print("[${d}, Block#{d}]", .{@enumToInt(phi.decl), @enumToInt(edge.source_block)});
                    if(phi.next != .none) {
                        std.debug.print(", ", .{});
                    }
                    current_phi = phi.next;
                }
                std.debug.print(")\n", .{});
            },
            .clobber => unreachable,
        }
    }
    std.debug.print("\n", .{});
}

pub var decls: DeclIndex.List(Decl) = undefined;
pub var blocks: BlockIndex.List(BasicBlock) = undefined;
pub var edges: BlockEdgeIndex.List(InstructionToBlockEdge) = undefined;
pub var phi_operands: PhiOperandIndex.List(PhiOperand) = undefined;
pub var function_arguments: FunctionArgumentIndex.List(FunctionArgument) = undefined;

pub fn init() !void {
    decls = try DeclIndex.List(Decl).init(std.heap.page_allocator);
    blocks = try BlockIndex.List(BasicBlock).init(std.heap.page_allocator);
    edges = try BlockEdgeIndex.List(InstructionToBlockEdge).init(std.heap.page_allocator);
    phi_operands = try PhiOperandIndex.List(PhiOperand).init(std.heap.page_allocator);
    function_arguments = try FunctionArgumentIndex.List(FunctionArgument).init(std.heap.page_allocator);
}
