const std = @import("std");
const c_bestline = @cImport(@cInclude("bestline.h"));

pub fn setup() !void {
    bestlineSetCompletionCallback(completionCallback);
    bestlineSetHintsCallback(hintsCallback);
    // TODO: history per executable
    // Discard any failures
    _ = c_bestline.bestlineHistoryLoad("history.txt");
}

pub fn getInput(stdout: anytype, stderr: anytype) ?Input {
    while (true) {
        const c_line = c_bestline.bestline("> ") orelse return null;
        defer std.c.free(c_line);

        const line = std.mem.sliceTo(c_line, 0);

        if (line.len == 0) {
            stdout.writeAll(help_menu) catch unreachable;
            continue;
        }

        if (line[0] == 'o') {
            // it is one of the output types

            // We only need to check with `endsWith` to hit both "orun" and "output run"
            if (std.mem.endsWith(u8, line, "run")) {
                history(c_line);
                return .output_run;
            }

            // same as above
            if (std.mem.endsWith(u8, line, "step")) {
                history(c_line);
                return .output_step;
            }
        } else {
            if (std.mem.eql(u8, line, "h") or std.mem.eql(u8, line, "?") or std.mem.eql(u8, line, "help")) {
                history(c_line);
                stdout.writeAll(help_menu) catch unreachable;
                continue;
            }

            if (std.mem.eql(u8, line, "q") or std.mem.eql(u8, line, "quit")) return null;

            if (std.mem.eql(u8, line, "run")) {
                history(c_line);
                return .run;
            }

            if (std.mem.eql(u8, line, "step")) {
                history(c_line);
                return .step;
            }

            if (std.mem.eql(u8, line, "whatif")) {
                history(c_line);
                return .whatif;
            }

            if (std.mem.eql(u8, line, "dump")) {
                history(c_line);
                return .dump;
            }

            if (std.mem.eql(u8, line, "reset")) {
                history(c_line);
                return .reset;
            }

            if (std.mem.startsWith(u8, line, "break")) {
                history(c_line);

                // break must be of the form "break H+" where H+ is one or more hex digits
                // which means it must have a minimum length of 7
                if (line.len < 7) {
                    stderr.print("invalid breakpoint specification provided: '{s}'\n", .{line}) catch unreachable;
                    continue;
                }

                var target_slice = line[6..];

                if (std.mem.startsWith(u8, target_slice, "0x")) {
                    // if the hex number starts with "0x" then there must be atleast one digit following "0x"
                    // meaning a minimum length of 3
                    if (target_slice.len < 3) {
                        stderr.print("invalid breakpoint specification provided: '{s}'\n", .{line}) catch unreachable;
                        continue;
                    }

                    target_slice = target_slice[2..];
                }

                return .{
                    .breakpoint = std.fmt.parseUnsigned(u64, target_slice, 16) catch |err| {
                        stderr.print("ERROR: unable to parse '{s}' as hex: {s}\n", .{ target_slice, @errorName(err) }) catch unreachable;
                        continue;
                    },
                };
            }
        }

        history(c_line);
        stderr.writeAll("ERROR: unknown option\n") catch unreachable;
        stdout.writeAll(help_menu) catch unreachable;
    }
}

fn history(c_line: [*c]u8) void {
    // FIXME: Is it a good idea to save the history after *every* keypress?
    if (c_bestline.bestlineHistoryAdd(c_line) == 1) {
        _ = c_bestline.bestlineHistorySave("history.txt");
    }
}

pub const Input = union(enum) {
    run,
    output_run,
    step,
    output_step,
    whatif,
    dump,
    reset,
    breakpoint: u64,
};

fn completionCallback(c_buf: [*:0]const u8, completion: *Completions) callconv(.C) void {
    const buf = std.mem.sliceTo(c_buf, 0);

    switch (buf.len) {
        0 => completion.addCompletion("help"),
        1 => switch (buf[0]) {
            'h' => completion.addCompletion("help"),
            'o' => {
                completion.addCompletion("orun");
                completion.addCompletion("ostep");
            },
            'r' => {
                completion.addCompletion("run");
                completion.addCompletion("reset");
            },
            's' => completion.addCompletion("step"),
            'w' => completion.addCompletion("whatif"),
            'b' => completion.addCompletion("break "),
            'd' => completion.addCompletion("dump"),
            'q' => completion.addCompletion("quit"),
            else => {},
        },
        2 => {
            if (std.mem.eql(u8, buf, "he")) completion.addCompletion("help");
            if (std.mem.eql(u8, buf, "ru")) completion.addCompletion("run");
            if (std.mem.eql(u8, buf, "or")) completion.addCompletion("orun");
            if (std.mem.eql(u8, buf, "ou")) {
                completion.addCompletion("output run");
                completion.addCompletion("output step");
            }
            if (std.mem.eql(u8, buf, "os")) completion.addCompletion("ostep");
            if (std.mem.eql(u8, buf, "wh")) completion.addCompletion("whatif");
            if (std.mem.eql(u8, buf, "br")) completion.addCompletion("break ");
            if (std.mem.eql(u8, buf, "re")) completion.addCompletion("reset");
            if (std.mem.eql(u8, buf, "qu")) completion.addCompletion("quit");
        },
        3 => {
            if (std.mem.eql(u8, buf, "hel")) completion.addCompletion("help");
            if (std.mem.eql(u8, buf, "oru")) completion.addCompletion("orun");
            if (std.mem.eql(u8, buf, "out")) {
                completion.addCompletion("output run");
                completion.addCompletion("output step");
            }
            if (std.mem.eql(u8, buf, "ost")) completion.addCompletion("ostep");
            if (std.mem.eql(u8, buf, "wha")) completion.addCompletion("whatif");
            if (std.mem.eql(u8, buf, "bre")) completion.addCompletion("break ");
            if (std.mem.eql(u8, buf, "res")) completion.addCompletion("reset");
            if (std.mem.eql(u8, buf, "qui")) completion.addCompletion("quit");
        },
        4 => {
            if (std.mem.eql(u8, buf, "outp")) {
                completion.addCompletion("output run");
                completion.addCompletion("output step");
            }
            if (std.mem.eql(u8, buf, "oste")) completion.addCompletion("ostep");
            if (std.mem.eql(u8, buf, "what")) completion.addCompletion("whatif");
            if (std.mem.eql(u8, buf, "brea")) completion.addCompletion("break ");
            if (std.mem.eql(u8, buf, "rese")) completion.addCompletion("reset");
        },
        5 => {
            if (std.mem.eql(u8, buf, "outpu")) {
                completion.addCompletion("output run");
                completion.addCompletion("output step");
            }
            if (std.mem.eql(u8, buf, "whati")) completion.addCompletion("whatif");
        },
        6 => {
            if (std.mem.eql(u8, buf, "output")) {
                completion.addCompletion("output run");
                completion.addCompletion("output step");
            }
        },
        7 => {
            if (std.mem.eql(u8, buf, "output ")) {
                completion.addCompletion("output run");
                completion.addCompletion("output step");
            }
        },
        8 => {
            if (std.mem.eql(u8, buf, "output r")) completion.addCompletion("output run");
            if (std.mem.eql(u8, buf, "output s")) completion.addCompletion("output step");
        },
        9 => {
            if (std.mem.eql(u8, buf, "output ru")) completion.addCompletion("output run");
            if (std.mem.eql(u8, buf, "output st")) completion.addCompletion("output step");
        },
        10 => {
            if (std.mem.eql(u8, buf, "output ste")) completion.addCompletion("output step");
        },
        else => {},
    }
}

fn hintsCallback(c_buf: [*:0]const u8, ansi1: *[*:0]const u8, ansi2: *[*:0]const u8) callconv(.C) ?[*:0]const u8 {
    _ = ansi1;
    _ = ansi2;

    const buf = std.mem.sliceTo(c_buf, 0);
    if (std.mem.startsWith(u8, buf, "break")) {
        if (buf.len == 5) return " [addr]";
        if (buf.len == 6) return "[addr]";
    }

    return null;
}

pub const help_menu =
    \\help:
    \\    ?|h|help|<Enter> - this help menu
    \\                 run - run without output (this will not stop unless a breakpoint is hit, or an error)
    \\     orun|output run - run with output (this will not stop unless a breakpoint is hit, or an error)
    \\                step - single step without output
    \\   ostep|output step - single step with output
    \\              whatif - display what the next instruction will do, without executing it
    \\        break [addr] - set breakpoint, [addr] must be in hex, blank [addr] clears the breakpoint
    \\                dump - dump machine state
    \\               reset - reset machine
    \\              q|quit - quit
    \\
;

const Completions = extern struct {
    len: c_ulong,
    cvec: [*c][*c]u8,

    pub inline fn addCompletion(self: *Completions, str: [:0]const u8) void {
        c_bestline.bestlineAddCompletion(@ptrCast([*c]c_bestline.bestlineCompletions, self), str.ptr);
    }
};

const CompletionCallback = fn (buf: [*:0]const u8, completions: *Completions) callconv(.C) void;

extern fn bestlineSetCompletionCallback(callback: ?*const CompletionCallback) void;

const HintsCallback = fn (buf: [*:0]const u8, ansi1: *[*:0]const u8, ansi2: *[*:0]const u8) callconv(.C) ?[*:0]const u8;

extern fn bestlineSetHintsCallback(callback: ?*const HintsCallback) void;

comptime {
    refAllDeclsRecursive(@This());
}

// This code is from `std.testing.refAllDeclsRecursive` but as it is in the file it can access private decls
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (decl.is_pub) {
            if (@TypeOf(@field(T, decl.name)) == type) {
                switch (@typeInfo(@field(T, decl.name))) {
                    .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                    else => {},
                }
            }
            _ = @field(T, decl.name);
        }
    }
}
