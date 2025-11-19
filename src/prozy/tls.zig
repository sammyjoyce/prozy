const std = @import("std");
const tls = @import("std").crypto.tls;

pub const TlsProvider = struct {
    allocator: std.mem.Allocator,
    ca_cert: tls.Certificate,
    ca_key: tls.Key,

    pub fn init(allocator: std.mem.Allocator) !TlsProvider {
        var self = TlsProvider{
            .allocator = allocator,
            .ca_cert = undefined,
            .ca_key = undefined,
        };

        // For simplicity, we'll generate a self-signed certificate.
        // In a real production environment, you would load this from a file.
        var ca = try tls.Certificate.initSelfSigned(allocator, .{
            .subject = .{ .common_name = "Prozy Gateway" },
            .key_type = .rsa_2048,
            .valid_from = std.time.timestamp(),
            .valid_to = std.time.timestamp() + (365 * 24 * 60 * 60), // 1 year
        });

        self.ca_cert = ca.certificate;
        self.ca_key = ca.key;

        return self;
    }

    pub fn deinit(self: *TlsProvider) void {
        self.ca_cert.deinit();
        self.ca_key.deinit();
    }

    pub fn wrapServer(self: *TlsProvider, io: std.Io, server: *std.Io.net.Server) !std.Io.net.Server.Tls {
        var config = tls.ServerConfig.init(self.allocator);
        try config.addCertificate(self.ca_cert, self.ca_key);

        return server.tls(io, config);
    }
};
