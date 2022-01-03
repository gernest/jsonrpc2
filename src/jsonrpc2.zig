const std = @import("std");
const json = std.json;

pub const json_rpc_version = "2.0";
const default_message_size: usize = 8192;
const Allocator = std.mem.Allocator;

pub const ErrorCode = enum(i64) {
    // UnknownError should be used for all non coded errors.
    UnknownError = -32001,

    // ParseError is used when invalid JSON was received by the server.
    ParseError = -32700,

    //InvalidRequest is used when the JSON sent is not a valid Request object.
    InvalidRequest = -32600,

    // MethodNotFound should be returned by the handler when the method does
    // not exist / is not available.
    MethodNotFound = -32601,

    // InvalidParams should be returned by the handler when method
    // parameter(s) were invalid.
    InvalidParams = -32602,

    // InternalError is not currently returned but defined for completeness.
    InternalError = -32603,

    //ServerOverloaded is returned when a message was refused due to a
    //server being temporarily unable to accept any new messages.
    ServerOverloaded = -32000,
};

pub fn RPCError(
    comptime ResultErrorData: type,
) type {
    return struct {
        code: i64,
        message: []const u8,
        data: ?ResultErrorData,
    };
}

const HdrContentLength = "Content-Length";

pub const ID = union(enum) {
    Name: []const u8,
    Number: i64,
};

pub fn RPCequest(
    comptime ParamType: type,
) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: ?ParamType = null,
        id: ID,
    };
}

test "Request.ecnode jsonrpc 2.0" {
    var dyn = DynamicWriter.init(std.testing.allocator);
    defer dyn.deinit();

    var r = RPCequest(struct {}){
        .method = "",
        .id = .{
            .Number = 0,
        },
    };
    try json.stringify(r, .{}, dyn.writer());
    const expect =
        \\{"jsonrpc":"2.0","method":"","params":null,"id":0}
    ;
    try std.testing.expectEqualStrings(expect, dyn.list.items);
    // std.debug.print("\n{s}\n", .{dyn.list.items});
}

pub fn RPCResponse(
    comptime ResultType: type,
    comptime ResultErrorData: type,
) type {
    return struct {
        jsonrpc: []const u8,
        result: ?ResultType,
        @"error": ?RPCError(ResultErrorData),
        id: ?ID,
    };
}

pub fn Conn(
    // Read/write types and options
    comptime ReaderType: type,
    comptime read_buffer_size: usize,
    comptime WriterType: type,

    //rpc
    comptime ParamType: type,
    comptime ResultType: type,
    comptime ResultErrorDataType: type,
) type {
    return struct {
        const Self = @This();

        id_sequence: std.atomic.Atomic(u64),
        request_queue: Queue,
        response_queue: Queue,

        read_stream: ReadStream,
        write_sream: WriterType,

        allocator: Allocator,

        pub const ReadStream = std.io.BufferedReader(read_buffer_size, ReaderType);

        pub const Request = RPCequest(ParamType);

        pub const Response = RPCResponse(ResultType, ResultErrorDataType);

        const QueueEntry = struct {
            request: Request = undefined,
            response: ?Response = null,

            arena: std.heap.ArenaAllocator,

            fn init(a: Allocator) QueueEntry {
                return QueueEntry{
                    .arena = std.heap.ArenaAllocator.init(a),
                };
            }
        };

        const Queue = std.atomic.Queue(QueueEntry);

        pub fn init(
            write_to: WriterType,
            read_from: ReaderType,
        ) Self {
            return Self{
                .id_sequence = std.atomic.Atomic(u64).init(0),
                .read_stream = ReadStream{
                    .unbuffered_reader = read_from,
                },
                .write_stream = write_to,
                .request_queue = Queue.init(),
                .response_queue = Queue.init(),
            };
        }

        fn trimSpace(s: []const u8) []const u8 {
            return std.mem.trim(u8, s, [_]u8{ ' ', '\n', '\r' });
        }

        fn newQueueEntry(self: *Self) !QueueEntry {
            var q = try self.allocator.create(QueueEntry);
            q.* = QueueEntry.init(self.allocator);
            return q;
        }

        // readRequest reads request for the read_stream and queue decoded request.
        fn readRequest(self: *Self) !void {
            var r = self.read_stream.reader();
            var q = try self.newQueueEntry();

            errdefer {
                // q is not going anywhere we need to destroy it.
                q.arena.deinit();
                self.allocator.destroy(q);
            }

            // all allocations relating to the incoming reques are tied to the
            // QueueEntry and will be freed once
            var alloc = q.arena.allocator();
            var length: usize = 0;
            while (true) {
                var line = try r.readUntilDelimiterOrEofAlloc(alloc, '\n', default_message_size);
                if (trimSpace(line).len == 0) {
                    break;
                }
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
                const name = line[0..colon];
                const value = trimSpace(line[colon + 1 ..]);
                if (std.mem.eql(u8, name, HdrContentLength)) {
                    length = try std.fmt.parseInt(usize, value, 10);
                }
            }
            if (length == 0) {
                return error.MissingContentLengthHeader;
            }
            const data = try alloc.alloc(u8, length);
            try r.readNoEof(data);

            q.request = try json.parse(Request, &json.TokenStream.init(data), json.ParseOptions{
                .allocator = alloc,
                .duplicate_field_behavior = .UseFirst,
                .ignore_unknown_fields = true,
            });

            var node = self.allocator.create(Queue.Node);
            node.* = Queue.Node{
                .prev = undefined,
                .next = undefined,
                .data = q,
            };
            self.request_queue.put(node);
        }

        fn handleResponse(self: *Self, node: *Queue.Node) !void {
            self.response_queue.put(node);
        }

        fn respond(self: *Self, node: *Queue.Node) !void {
            defer {
                node.data.arena.deinit();
                self.allocator.destroy(node);
            }
            try self.writeResponse(node.data);
        }

        fn writeResponse(self: *Self, q: *QueueEntry) !void {
            if (self.response) |response| {
                var w = DynamicWriter.init(q.arena.allocator());
                try json.stringify(response, .{}, w.writer());
                try self.write_sream.print("{}: {}\r\n\r\n", .{
                    HdrContentLength, w.list.items.len,
                });
                try self.write_sream.write(w.list.items);
            }
        }
    };
}

const DynamicWriter = struct {
    list: std.ArrayList(u8),

    fn init(a: Allocator) DynamicWriter {
        return .{ .list = std.ArrayList(u8).init(a) };
    }

    fn deinit(self: *DynamicWriter) void {
        self.list.deinit();
    }

    const Writer = std.io.Writer(*DynamicWriter, Allocator.Error, write);

    fn write(self: *DynamicWriter, bytes: []const u8) Allocator.Error!usize {
        try self.list.appendSlice(bytes);
        return bytes.len;
    }

    fn writer(self: *DynamicWriter) Writer {
        return .{ .context = self };
    }
};
