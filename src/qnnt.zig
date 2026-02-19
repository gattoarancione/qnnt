const std = @import("std");
const net = std.net;

const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 2222);
