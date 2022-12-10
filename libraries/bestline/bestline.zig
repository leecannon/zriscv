const std = @import("std");
pub const c = @cImport(@cInclude("bestline.h"));

pub const Completions = extern struct {
    len: c_ulong,
    cvec: [*c][*c]u8,

    pub inline fn addCompletion(self: *Completions, str: [:0]const u8) void {
        c.bestlineAddCompletion(@ptrCast([*c]c.bestlineCompletions, self), str.ptr);
    }
};

pub const CompletionCallback = *const fn (buf: [*:0]const u8, completions: *Completions) callconv(.C) void;

pub extern fn bestlineSetCompletionCallback(callback: CompletionCallback) void;

pub const HintsCallback = *const fn (buf: [*:0]const u8, ansi1: *[*:0]const u8, ansi2: *[*:0]const u8) callconv(.C) ?[*:0]const u8;

pub extern fn bestlineSetHintsCallback(callback: HintsCallback) void;
