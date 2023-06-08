const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const unicode = std.unicode;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const xml_node = @import("node.zig");
const Node = xml_node.Node;
const OwnedNode = xml_node.OwnedNode;
const Scanner = @import("Scanner.zig");
const Token = Scanner.Token;

/// An event emitted by a reader.
pub const Event = union(enum) {
    element_start: ElementStart,
    element_content: ElementContent,
    element_end: ElementEnd,
    attribute_start: AttributeStart,
    attribute_content: AttributeContent,
    comment_start,
    comment_content: CommentContent,
    pi_start: PiStart,
    pi_content: PiContent,

    pub const ElementStart = struct {
        name: []const u8,
    };

    pub const ElementContent = struct {
        element_name: []const u8,
        content: Content,
    };

    pub const ElementEnd = struct {
        name: []const u8,
    };

    pub const AttributeStart = struct {
        element_name: []const u8,
        name: []const u8,
    };

    pub const AttributeContent = struct {
        element_name: []const u8,
        attribute_name: []const u8,
        content: Content,
        final: bool = false,
    };

    pub const CommentContent = struct {
        content: []const u8,
        final: bool = false,
    };

    pub const PiStart = struct {
        target: []const u8,
    };

    pub const PiContent = struct {
        pi_target: []const u8,
        content: []const u8,
        final: bool = false,
    };

    pub const Content = union(enum) {
        text: []const u8,
        /// An entity reference (such as `&amp;`). Guaranteed to be a valid entity name.
        entity_ref: []const u8,
        /// A character reference (such as `&#32;` or `&#x20;`). Guaranteed to be a valid Unicode codepoint.
        char_ref: u21,
    };
};

/// A map of predefined XML entities to their replacement text.
///
/// Until DTDs are understood and parsed, these are the only named entities
/// supported by this parser.
pub const entities = std.ComptimeStringMap([]const u8, .{
    .{ "amp", "&" },
    .{ "lt", "<" },
    .{ "gt", ">" },
    .{ "apos", "'" },
    .{ "quot", "\"" },
});

/// Wraps a `std.io.Reader` in a `Reader` with the default buffer size (4096).
pub fn reader(allocator: Allocator, r: anytype) Reader(4096, @TypeOf(r)) {
    return Reader(4096, @TypeOf(r)).init(allocator, r);
}

/// A streaming XML parser wrapping a `std.io.Reader`.
///
/// This parser is a higher-level wrapper around a `Scanner`, providing an API
/// which vaguely mimics a StAX pull-based XML parser as found in other
/// libraries. It performs additional well-formedness checks on the input
/// which `Scanner` is unable to perform due to its design, such as verifying
/// that end element tag names match the corresponding start tag names.
///
/// An internal buffer is used to store document content read from the reader,
/// and the size of the buffer (`buffer_size`) limits the maximum length of
/// names (element names, attribute names, PI targets, entity names, etc.) and
/// content events (but not the total length of content, since multiple content
/// events can be emitted for a single containing context). An allocator is
/// also used to keep track of internal state, such as a stack of containing
/// element names.
pub fn Reader(comptime buffer_size: usize, comptime ReaderType: type) type {
    return struct {
        scanner: Scanner,
        reader: ReaderType,
        buffer: [buffer_size]u8 = undefined,
        /// A stack of element names enclosing the current context.
        element_names: ArrayListUnmanaged([]u8) = .{},
        /// The last element name, if we just encountered the end of an empty element.
        last_element_name: ?[]u8 = null,
        /// The current attribute name we're parsing, if any.
        attribute_name: ?[]u8 = null,
        /// The current PI target we're parsing, if any.
        pi_target: ?[]u8 = null,
        allocator: Allocator,

        const Self = @This();

        pub const Error = error{
            SyntaxError,
            UnexpectedEndOfInput,
            Overflow,
        } || Allocator.Error || ReaderType.Error;

        pub fn init(allocator: Allocator, r: ReaderType) Self {
            return .{
                .scanner = Scanner{},
                .reader = r,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.element_names.items) |name| {
                self.allocator.free(name);
            }
            self.element_names.deinit(self.allocator);

            if (self.last_element_name) |last_element_name| {
                self.allocator.free(last_element_name);
            }

            if (self.attribute_name) |attribute_name| {
                self.allocator.free(attribute_name);
            }

            if (self.pi_target) |pi_target| {
                self.allocator.free(pi_target);
            }

            self.* = undefined;
        }

        /// Returns the next event from the input.
        ///
        /// The returned event is only valid until the next call to `next`,
        /// `nextNode`, or `deinit`.
        pub fn next(self: *Self) Error!?Event {
            if (self.last_element_name) |last_element_name| {
                // last_element_name is only a holding area to return a valid
                // element_end event for an empty element. Since events are
                // invalidated after the next call to next, we no longer need
                // it.
                self.allocator.free(last_element_name);
                self.last_element_name = null;
            }

            if (self.scanner.pos > 0) {
                // If the scanner position is > 0, that means we emitted an event
                // on the last call to next, and should try to reset the
                // position again in an effort to not run out of buffer space
                // (ideally, the scanner should be resettable after every token,
                // but we do not depend on this).
                if (self.scanner.resetPos()) |token| {
                    if (try self.tokenToEvent(token)) |event| {
                        return event;
                    }
                } else |_| {
                    // Failure to reset isn't fatal (yet); we can still try to
                    // complete the token below
                }
            }

            while (true) {
                if (self.scanner.pos == self.buffer.len) {
                    const token = self.scanner.resetPos() catch |e| switch (e) {
                        error.CannotReset => return error.Overflow,
                    };
                    if (try self.tokenToEvent(token)) |event| {
                        return event;
                    }
                }

                const c = self.reader.readByte() catch |e| switch (e) {
                    error.EndOfStream => {
                        try self.scanner.endInput();
                        return null;
                    },
                    else => |other| return other,
                };
                self.buffer[self.scanner.pos] = c;
                if (try self.tokenToEvent(try self.scanner.next(c))) |event| {
                    return event;
                }
            }
        }

        fn tokenToEvent(self: *Self, token: Token) !?Event {
            switch (token) {
                .ok => return null,

                // This should eventually be handled, but currently it is not
                // very useful
                .xml_declaration => return null,

                .element_start => |element_start| {
                    const name = try self.bufRangeDupe(element_start.name);
                    errdefer self.allocator.free(name);
                    try self.element_names.append(self.allocator, name);
                    return .{ .element_start = .{ .name = name } };
                },

                .element_content => |element_content| return .{ .element_content = .{
                    .element_name = self.element_names.getLast(),
                    .content = try self.convertContent(element_content.content),
                } },

                .element_end => |element_end| {
                    const name = self.bufRange(element_end.name);
                    const current_element_name = self.element_names.pop();
                    defer self.allocator.free(current_element_name);
                    if (!std.mem.eql(u8, name, current_element_name)) {
                        return error.SyntaxError;
                    }
                    return .{ .element_end = .{ .name = name } };
                },

                .element_end_empty => {
                    const current_element_name = self.element_names.pop();
                    self.last_element_name = current_element_name;
                    return .{ .element_end = .{ .name = current_element_name } };
                },

                .attribute_start => |attribute_start| {
                    if (self.attribute_name) |attribute_name| {
                        self.allocator.free(attribute_name);
                    }
                    const name = try self.bufRangeDupe(attribute_start.name);
                    self.attribute_name = name;
                    return .{ .attribute_start = .{
                        .element_name = self.element_names.getLast(),
                        .name = name,
                    } };
                },

                .attribute_content => |attribute_content| return .{ .attribute_content = .{
                    .element_name = self.element_names.getLast(),
                    .attribute_name = self.attribute_name.?,
                    .content = try self.convertContent(attribute_content.content),
                    .final = attribute_content.final,
                } },

                .comment_start => return .comment_start,

                .comment_content => |comment_content| return .{ .comment_content = .{
                    .content = self.bufRange(comment_content.content),
                    .final = comment_content.final,
                } },

                .pi_start => |pi_start| {
                    if (self.pi_target) |pi_target| {
                        self.allocator.free(pi_target);
                    }
                    const target = try self.bufRangeDupe(pi_start.target);
                    self.pi_target = target;
                    return .{ .pi_start = .{ .target = target } };
                },

                .pi_content => |pi_content| return .{ .pi_content = .{
                    .pi_target = self.pi_target.?,
                    .content = self.bufRange(pi_content.content),
                    .final = pi_content.final,
                } },
            }
        }

        fn convertContent(self: *const Self, content: Token.Content) !Event.Content {
            return switch (content) {
                .text => |text| .{ .text = self.bufRange(text) },
                .entity_ref => |entity_ref| content: {
                    const name = self.bufRange(entity_ref);
                    if (!entities.has(name)) {
                        return error.SyntaxError;
                    }
                    break :content .{ .entity_ref = name };
                },
                .char_ref => |char_ref| .{ .char_ref = char_ref },
            };
        }

        inline fn bufRange(self: *const Self, range: Scanner.Range) []const u8 {
            return self.buffer[range.start..range.end];
        }

        inline fn bufRangeDupe(self: *const Self, range: Scanner.Range) ![]u8 {
            return try self.allocator.dupe(u8, self.bufRange(range));
        }

        /// Reads the node whose start event (`start_event`) was returned by
        /// the last call to `next`.
        ///
        /// `start_event` must have been returned by the last call to `next`,
        /// and it must be one of the "start" events, listed below with the
        /// type of node which will be returned:
        ///
        /// - `element_start` - `Element`
        /// - `attribute_start` - `Attribute`
        /// - `comment_start` - `Comment`
        /// - `pi_start` - `Pi`
        ///
        /// The returned node is owned by the caller, so the caller is
        /// responsible for calling `deinit` on it when done (but it remains
        /// valid until that point, even after further calls to `next` or
        /// `nextNode`).
        pub fn nextNode(self: *Self, allocator: Allocator, start_event: Event) Error!OwnedNode {
            var arena = ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            const node: Node = switch (start_event) {
                .element_start => |element_start| .{ .element = try self.nextElementNode(a, element_start) },
                .attribute_start => |attribute_start| .{ .attribute = try self.nextAttributeNode(a, attribute_start) },
                .comment_start => .{ .comment = try self.nextCommentNode(a) },
                .pi_start => |pi_start| .{ .pi = try self.nextPiNode(a, pi_start) },
                else => unreachable,
            };
            return .{ .node = node, .arena = arena };
        }

        fn nextElementNode(self: *Self, allocator: Allocator, element_start: Event.ElementStart) !Node.Element {
            const name = try allocator.dupe(u8, element_start.name);
            var children = ArrayListUnmanaged(Node){};
            var current_text = ArrayListUnmanaged(u8){};
            while (try self.next()) |event| {
                if (event != .element_content and current_text.items.len > 0) {
                    try children.append(allocator, .{ .text = .{ .content = try current_text.toOwnedSlice(allocator) } });
                }
                switch (event) {
                    .element_start => |sub_element_start| try children.append(allocator, .{
                        .element = try self.nextElementNode(allocator, sub_element_start),
                    }),
                    .element_content => |element_content| try appendContent(&current_text, allocator, element_content.content),
                    .element_end => return .{ .name = name, .children = children.items },
                    .attribute_start => |attribute_start| try children.append(allocator, .{
                        .attribute = try self.nextAttributeNode(allocator, attribute_start),
                    }),
                    .comment_start => try children.append(allocator, .{
                        .comment = try self.nextCommentNode(allocator),
                    }),
                    .pi_start => |pi_start| try children.append(allocator, .{
                        .pi = try self.nextPiNode(allocator, pi_start),
                    }),
                    else => unreachable,
                }
            }
            unreachable;
        }

        fn nextAttributeNode(self: *Self, allocator: Allocator, attribute_start: Event.AttributeStart) !Node.Attribute {
            const name = try allocator.dupe(u8, attribute_start.name);
            var value = ArrayListUnmanaged(u8){};
            while (try self.next()) |event| {
                const content_event = event.attribute_content;
                try appendContent(&value, allocator, content_event.content);
                if (content_event.final) {
                    return .{ .name = name, .value = value.items };
                }
            }
            unreachable;
        }

        fn nextCommentNode(self: *Self, allocator: Allocator) !Node.Comment {
            var content = ArrayListUnmanaged(u8){};
            while (try self.next()) |event| {
                const content_event = event.comment_content;
                try content.appendSlice(allocator, content_event.content);
                if (content_event.final) {
                    return .{ .content = content.items };
                }
            }
            unreachable;
        }

        fn nextPiNode(self: *Self, allocator: Allocator, pi_start: Event.PiStart) !Node.Pi {
            const target = try allocator.dupe(u8, pi_start.target);
            var content = ArrayListUnmanaged(u8){};
            while (try self.next()) |event| {
                const content_event = event.pi_content;
                try content.appendSlice(allocator, content_event.content);
                if (content_event.final) {
                    return .{
                        .target = target,
                        .content = content.items,
                    };
                }
            }
            unreachable;
        }

        fn appendContent(value: *ArrayListUnmanaged(u8), allocator: Allocator, content: Event.Content) !void {
            switch (content) {
                .text => |text| try value.appendSlice(allocator, text),
                .entity_ref => |entity_ref| try value.appendSlice(allocator, entities.get(entity_ref).?),
                .char_ref => |char_ref| {
                    var buf: [4]u8 = undefined;
                    const len = unicode.utf8Encode(char_ref, &buf) catch unreachable;
                    try value.appendSlice(allocator, buf[0..len]);
                },
            }
        }
    };
}

test "complex document" {
    try testValid(
        \\<?xml version="1.0"?>
        \\<?some-pi?>
        \\<!-- A processing instruction with content follows -->
        \\<?some-pi-with-content content?>
        \\<root>
        \\  <p class="test">Hello, <![CDATA[world!]]></p>
        \\  <line />
        \\  <?another-pi?>
        \\  Text content goes here.
        \\  <div><p>&amp;</p></div>
        \\</root>
        \\<!-- Comments are allowed after the end of the root element -->
        \\
        \\<?comment So are PIs ?>
        \\
        \\
    , &.{
        .{ .pi_start = .{ .target = "some-pi" } },
        .{ .pi_content = .{ .pi_target = "some-pi", .content = "", .final = true } },
        .comment_start,
        .{ .comment_content = .{ .content = " A processing instruction with content follows ", .final = true } },
        .{ .pi_start = .{ .target = "some-pi-with-content" } },
        .{ .pi_content = .{ .pi_target = "some-pi-with-content", .content = "content", .final = true } },
        .{ .element_start = .{ .name = "root" } },
        .{ .element_content = .{ .element_name = "root", .content = .{ .text = "\n  " } } },
        .{ .element_start = .{ .name = "p" } },
        .{ .attribute_start = .{ .element_name = "p", .name = "class" } },
        .{ .attribute_content = .{ .element_name = "p", .attribute_name = "class", .content = .{ .text = "test" }, .final = true } },
        .{ .element_content = .{ .element_name = "p", .content = .{ .text = "Hello, " } } },
        .{ .element_content = .{ .element_name = "p", .content = .{ .text = "world!" } } },
        .{ .element_end = .{ .name = "p" } },
        .{ .element_content = .{ .element_name = "root", .content = .{ .text = "\n  " } } },
        .{ .element_start = .{ .name = "line" } },
        .{ .element_end = .{ .name = "line" } },
        .{ .element_content = .{ .element_name = "root", .content = .{ .text = "\n  " } } },
        .{ .pi_start = .{ .target = "another-pi" } },
        .{ .pi_content = .{ .pi_target = "another-pi", .content = "", .final = true } },
        .{ .element_content = .{ .element_name = "root", .content = .{ .text = "\n  Text content goes here.\n  " } } },
        .{ .element_start = .{ .name = "div" } },
        .{ .element_start = .{ .name = "p" } },
        .{ .element_content = .{ .element_name = "p", .content = .{ .entity_ref = "amp" } } },
        .{ .element_end = .{ .name = "p" } },
        .{ .element_end = .{ .name = "div" } },
        .{ .element_content = .{ .element_name = "root", .content = .{ .text = "\n" } } },
        .{ .element_end = .{ .name = "root" } },
        .comment_start,
        .{ .comment_content = .{ .content = " Comments are allowed after the end of the root element ", .final = true } },
        .{ .pi_start = .{ .target = "comment" } },
        .{ .pi_content = .{ .pi_target = "comment", .content = "So are PIs ", .final = true } },
    });
}

fn testValid(input: []const u8, expected_events: []const Event) !void {
    var input_stream = std.io.fixedBufferStream(input);
    var input_reader = reader(testing.allocator, input_stream.reader());
    defer input_reader.deinit();
    var i: usize = 0;
    while (try input_reader.next()) |event| : (i += 1) {
        if (i >= expected_events.len) {
            std.debug.print("Unexpected event after end: {}\n", .{event});
            return error.TestFailed;
        }
        testing.expectEqualDeep(expected_events[i], event) catch |e| {
            std.debug.print("(at index {})\n", .{i});
            return e;
        };
    }
    if (i != expected_events.len) {
        std.debug.print("Expected {} events, found {}\n", .{ expected_events.len, i });
        return error.TestFailed;
    }
}

test "complex document nodes" {
    var input_stream = std.io.fixedBufferStream(
        \\<?xml version="1.0"?>
        \\<?some-pi?>
        \\<!-- A processing instruction with content follows -->
        \\<?some-pi-with-content content?>
        \\<root>
        \\  <p class="test">Hello, <![CDATA[world!]]></p>
        \\  <line />
        \\  <?another-pi?>
        \\  Text content goes here.
        \\  <div><p>&amp;</p></div>
        \\</root>
        \\<!-- Comments are allowed after the end of the root element -->
        \\
        \\<?comment So are PIs ?>
        \\
        \\
    );
    var input_reader = reader(testing.allocator, input_stream.reader());
    defer input_reader.deinit();

    // some-pi
    {
        const event = try input_reader.next();
        try testing.expect(event != null and event.? == .pi_start);
        var node = try input_reader.nextNode(testing.allocator, event.?);
        defer node.deinit();
        try testing.expectEqualDeep(Node{ .pi = .{ .target = "some-pi", .content = "" } }, node.node);
    }

    // comment
    {
        const event = try input_reader.next();
        try testing.expect(event != null and event.? == .comment_start);
        var node = try input_reader.nextNode(testing.allocator, event.?);
        defer node.deinit();
        try testing.expectEqualDeep(Node{ .comment = .{ .content = " A processing instruction with content follows " } }, node.node);
    }

    // some-pi-with-content
    {
        const event = try input_reader.next();
        try testing.expect(event != null and event.? == .pi_start);
        var node = try input_reader.nextNode(testing.allocator, event.?);
        defer node.deinit();
        try testing.expectEqualDeep(Node{ .pi = .{ .target = "some-pi-with-content", .content = "content" } }, node.node);
    }

    // root
    {
        const event = try input_reader.next();
        try testing.expect(event != null and event.? == .element_start);
        var node = try input_reader.nextNode(testing.allocator, event.?);
        defer node.deinit();
        try testing.expectEqualDeep(Node{ .element = .{ .name = "root", .children = &.{
            .{ .text = .{ .content = "\n  " } },
            .{ .element = .{ .name = "p", .children = &.{
                .{ .attribute = .{ .name = "class", .value = "test" } },
                .{ .text = .{ .content = "Hello, world!" } },
            } } },
            .{ .text = .{ .content = "\n  " } },
            .{ .element = .{ .name = "line", .children = &.{} } },
            .{ .text = .{ .content = "\n  " } },
            .{ .pi = .{ .target = "another-pi", .content = "" } },
            .{ .text = .{ .content = "\n  Text content goes here.\n  " } },
            .{ .element = .{ .name = "div", .children = &.{
                .{ .element = .{ .name = "p", .children = &.{
                    .{ .text = .{ .content = "&" } },
                } } },
            } } },
            .{ .text = .{ .content = "\n" } },
        } } }, node.node);
    }

    // comment
    {
        const event = try input_reader.next();
        try testing.expect(event != null and event.? == .comment_start);
        var node = try input_reader.nextNode(testing.allocator, event.?);
        defer node.deinit();
        try testing.expectEqualDeep(Node{ .comment = .{ .content = " Comments are allowed after the end of the root element " } }, node.node);
    }

    // comment
    {
        const event = try input_reader.next();
        try testing.expect(event != null and event.? == .pi_start);
        var node = try input_reader.nextNode(testing.allocator, event.?);
        defer node.deinit();
        try testing.expectEqualDeep(Node{ .pi = .{ .target = "comment", .content = "So are PIs " } }, node.node);
    }

    try testing.expect(try input_reader.next() == null);
}