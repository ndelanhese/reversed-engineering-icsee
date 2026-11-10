import Foundation

@main
struct RemoteProtocolTest {
    static func main() throws {
        let serial = "1234567890abcdef"
        let configuration = try RemoteLiveConfiguration(serial: serial, channel: 1, substream: true, username: "admin", password: "example")
        precondition(configuration.channel == 1 && configuration.substream)
        precondition((try? RemoteLiveConfiguration(serial: "bad,serial", channel: 1, substream: true, username: "admin", password: "example")) == nil)
        precondition((try? RemoteLiveConfiguration(serial: serial, channel: 0, substream: true, username: "admin", password: "example")) == nil)
        let cancelled = RemoteLiveClient(configuration: configuration)
        cancelled.cancel()
        do { try cancelled.run { _, _ in }; preconditionFailure("cancelled session started") }
        catch is CancellationError { }
        let decoder = RemoteDecoder(width: 480, fps: 5) { _ in }
        do { try decoder.write(codec: 99, data: Data([0])); preconditionFailure("unknown codec accepted") }
        catch RemoteProtocolError.invalidIdentifier { }
        decoder.stop()
        do { try decoder.write(codec: 3, data: Data([0])); preconditionFailure("stopped decoder accepted data") }
        catch is CancellationError { }
        let bootstrap = RemoteProtocol.bootstrapRequest()
        precondition(bootstrap.count == 104 && bootstrap.prefix(4) == Data([0x14, 0x20, 0xf4, 0x05]))
        let bootstrapReply = Data([0x14, 0x20, 0xf5, 0x05]) + Data("1.1.1.1".utf8) + Data(repeating: 0, count: 13)
        let bootstrapAddress = try RemoteProtocol.bootstrapResponse(bootstrapReply)
        precondition(bootstrapAddress == "1.1.1.1")
        let unsafeBootstrap = Data([0x14, 0x20, 0xf5, 0x05]) + Data("127.0.0.1".utf8) + Data(repeating: 0, count: 11)
        precondition((try? RemoteProtocol.bootstrapResponse(unsafeBootstrap)) == nil)
        let query = try RemoteProtocol.lookupRequest(serial: serial)
        precondition(query == Data([0x15, 0x20, 0x00, 0xb0]) + Data(serial.utf8))
        precondition((try? RemoteProtocol.lookupRequest(serial: "bad,serial")) == nil)
        let registration = try RemoteProtocol.registration(client: "!xmnatuuid-PhoneClient-123456789012", timestamp: 123, natType: 3)
        precondition(registration.prefix(4) == Data([0x12, 0x20, 0xea, 0x03]))
        precondition(registration.suffix(9) == Data([0, 123, 0, 0, 0, 3, 0, 0, 0]))
        precondition((try? RemoteProtocol.registration(client: "invalid\0client", timestamp: 123, natType: 3)) == nil)
        let proxy = try RemoteProtocol.proxyRegistration(client: "client", clientID: 1000, serial: serial, peerID: 7)
        precondition(proxy.count == 212 && proxy.prefix(4) == Data([0x12, 0x20, 0xb9, 0x0b]))
        precondition(proxy[4..<10] == Data("client".utf8) && proxy[104..<108] == Data([0xe8, 3, 0, 0]))
        precondition(proxy[108..<124] == Data(serial.utf8) && proxy.suffix(4) == Data([7, 0, 0, 0]))
        let hello = try RemoteProtocol.hello(client: "client", clientID: 1000)
        precondition(hello.count == 112 && hello.prefix(4) == Data([0x12, 0x20, 0xd0, 0x07]))
        precondition(hello[4..<8] == Data([0xe8, 3, 0, 0]) && hello[8..<14] == Data("client".utf8))
        precondition(RemoteProtocol.heartbeat(counter: 0x1234) == Data([0x12, 0x20, 0xd2, 0x07, 0x34, 0x12, 0, 0]))
        precondition(RemoteProtocol.keepAliveInterval(seconds: nil) == 14)
        precondition(RemoteProtocol.keepAliveInterval(seconds: 20) == 14)
        precondition(RemoteProtocol.keepAliveInterval(seconds: 0) == 1)
        try RemoteProtocol.checkLoginStatus(100)
        do { try RemoteProtocol.checkLoginStatus(203); preconditionFailure("rejected login accepted") }
        catch RemoteProtocolError.authentication { }
        let connect = try RemoteProtocol.connectRequest(client: "client", clientID: 1000, serial: serial, externalAddress: "1.1.1.1", externalPort: 4000, localAddress: "192.168.0.4", localPort: 4001, timestamp: 123)
        precondition(connect.count == 360 && connect.prefix(4) == Data([0x12, 0x20, 0xec, 0x03]))
        precondition(connect[4..<8] == Data([0xe8, 3, 0, 0]) && connect[108..<124] == Data(serial.utf8))
        precondition(connect[208..<215] == Data("1.1.1.1".utf8) && connect[224..<228] == Data([0xa0, 0x0f, 0xa1, 0x0f]))
        precondition((try? RemoteProtocol.connectRequest(client: "client", clientID: 1000, serial: serial, externalAddress: "127.0.0.1", externalPort: 4000, localAddress: "192.168.0.4", localPort: 4001, timestamp: 123)) == nil)
        var peerRequest = connect
        peerRequest.replaceSubrange(328..<332, with: [0xe8, 3, 0, 0])
        peerRequest.replaceSubrange(332..<339, with: Data("8.8.8.8".utf8))
        peerRequest.replaceSubrange(348..<352, with: [0xd2, 0x04, 0, 0])
        let peer = try RemoteProtocol.peerRequest(peerRequest, clientID: 1000)
        precondition(peer.address == "1.1.1.1" && peer.port == 4000 && peer.proxyAddress == "8.8.8.8" && peer.proxyPort == 1234)
        precondition((try? RemoteProtocol.peerRequest(peerRequest, clientID: 1001)) == nil)
        var directPeer = peerRequest
        directPeer.replaceSubrange(332..<352, with: Data(repeating: 0, count: 20))
        let withoutProxy = try RemoteProtocol.peerRequest(directPeer, clientID: 1000)
        precondition(withoutProxy.proxyAddress == nil && withoutProxy.proxyPort == nil)
        var reply = Data(repeating: 0, count: 140)
        reply.replaceSubrange(0..<8, with: [0x15, 0x20, 0x01, 0xb0, 1, 0, 0, 0])
        reply.replaceSubrange(108..<115, with: Data("1.1.1.1".utf8))
        reply.replaceSubrange(128..<132, with: [0x3d, 0x22, 0, 0])
        let result = try RemoteProtocol.lookupResponse(reply)
        precondition(result.address == "1.1.1.1" && result.port == 8765)
        precondition((try? RemoteProtocol.lookupResponse(reply.prefix(139))) == nil)
        var rejected = reply
        rejected[4] = 0
        precondition((try? RemoteProtocol.lookupResponse(rejected)) == nil)
        let message = Data([0xff, 0x00, 0x01])
        let wire = try RemoteProtocol.reliableData(sequence: 42, payload: message)
        let expectedWire = Data([0x12, 0x20, 0xd3, 0x07, 0, 0, 15, 0, 0, 0, 0, 0, 0x58, 0x4d, 0x49, 0x50, 42, 0, 0, 0, 1, 14, 0, 0, 0xff, 0, 1])
        precondition(wire == expectedWire)
        let decoded = try RemoteProtocol.reliablePacket(wire)
        precondition(decoded.sequence == 42 && decoded.flags == 14 && decoded.payload == message)
        var dataWithFlags = wire
        dataWithFlags[22] = 0x12
        let decodedWithFlags = try RemoteProtocol.reliablePacket(dataWithFlags)
        precondition(decodedWithFlags.payload == message)
        let ack = try RemoteProtocol.reliableAck(sequence: 42)
        let decodedAck = try RemoteProtocol.reliablePacket(ack)
        precondition(decodedAck.sequence == 42 && decodedAck.flags == 1 && decodedAck.payload.isEmpty)
        var selectiveAck = ack
        selectiveAck[22] = 0x40
        selectiveAck[23] = 0x02
        let parsedSelectiveAck = try RemoteProtocol.reliablePacket(selectiveAck)
        precondition(parsedSelectiveAck.sequence == 42 && parsedSelectiveAck.flags & 3 == 1)
        precondition((try? RemoteProtocol.reliablePacket(wire.dropLast())) == nil)
        var receiver = RemoteProtocol.ReliableReceiver()
        let early = try receiver.accept(sequence: 1, flags: 10, payload: Data("lo".utf8))
        precondition(early.isEmpty)
        let completed = try receiver.accept(sequence: 0, flags: 6, payload: Data("hel".utf8))
        precondition(completed == [Data("hello".utf8)])
        let duplicate = try receiver.accept(sequence: 1, flags: 10, payload: Data("lo".utf8))
        precondition(duplicate.isEmpty)
        precondition((try? receiver.accept(sequence: 2, flags: 10, payload: message)) == nil)
        var media = RemoteProtocol.LiveMedia()
        let key = Data([0, 0, 1, 0xfc, 3, 15, 80, 45, 0, 0, 0, 0, 3, 0, 0, 0, 0xaa, 0xbb, 0xcc])
        let firstMedia = try media.append(Data([9, 8, 7]) + key.prefix(12))
        precondition(firstMedia.isEmpty)
        let secondMedia = try media.append(Data(key.dropFirst(12)))
        precondition(secondMedia.count == 1 && secondMedia[0].codec == 3 && secondMedia[0].payload == Data([0xaa, 0xbb, 0xcc]))
        let delta = Data([0, 0, 1, 0xfd, 2, 0, 0, 0, 0xdd, 0xee])
        let thirdMedia = try media.append(delta)
        precondition(thirdMedia.count == 1 && thirdMedia[0].payload == Data([0xdd, 0xee]))
        var sender = RemoteProtocol.ReliableSender()
        let outbound = try sender.start(message, at: 10)
        let outboundPacket = try RemoteProtocol.reliablePacket(outbound)
        precondition(outboundPacket.sequence == 0)
        precondition(sender.pendingPacket == outbound)
        let teardown = try sender.teardown(message)
        let teardownPacket = try RemoteProtocol.reliablePacket(teardown)
        precondition(teardownPacket.sequence == 1 && sender.isPending)
        precondition(sender.retry(at: 10.5) == nil)
        precondition(sender.retry(at: 11) == outbound)
        try sender.acknowledge(sequence: 0, count: 1)
        precondition(sender.pendingPacket == nil)
        precondition(sender.retry(at: 12) == nil)
        if CommandLine.arguments.count > 1, let port = UInt16(CommandLine.arguments[1]) {
            precondition((try? RemoteLookup.exchange(host: "127.0.0.1", port: port, request: Data("ping".utf8), timeout: 2)) == nil)
            let reply = try RemoteLookup.exchange(host: "127.0.0.1", port: port, request: Data("ping".utf8), timeout: 2, allowPrivate: true)
            precondition(reply == Data("pong".utf8))
        }
        print("PASS: remote lookup, UDP framing and media parsing")
    }
}
