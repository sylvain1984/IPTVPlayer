import CryptoKit
import Foundation

struct RTCTokenGenerator {

    static func viewerToken(
        appId: String, appKey: String, roomId: String, userId: String,
        expireSeconds: Int = 86400
    ) -> String {
        let expireAt = UInt32(Date().timeIntervalSince1970) + UInt32(expireSeconds)
        let privs: [(UInt16, UInt32)] = [(0,expireAt),(1,expireAt),(2,expireAt),(3,expireAt),(4,expireAt),(5,expireAt)]
        return build(appId: appId, appKey: appKey, roomId: roomId, userId: userId,
                     privileges: privs, expireAt: expireAt)
    }

    private static func build(
        appId: String, appKey: String, roomId: String, userId: String,
        privileges: [(UInt16, UInt32)], expireAt: UInt32
    ) -> String {
        let nonce    = UInt32.random(in: 0...UInt32.max)
        let issuedAt = UInt32(Date().timeIntervalSince1970)

        var msg = Data()
        msg += le(nonce); msg += le(issuedAt); msg += le(expireAt)
        msg += pstr(roomId); msg += pstr(userId)
        msg += le(UInt16(privileges.count))
        for (k, v) in privileges { msg += le(k); msg += le(v) }

        let sig = Data(HMAC<SHA256>.authenticationCode(
            for: msg, using: SymmetricKey(data: Data(appKey.utf8))
        ))

        var content = Data()
        content += le(UInt16(msg.count)); content += msg
        content += le(UInt16(sig.count)); content += sig

        return "001" + appId + content.base64EncodedString()
    }

    private static func le<T: FixedWidthInteger>(_ v: T) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: MemoryLayout<T>.size)
    }

    private static func pstr(_ s: String) -> Data {
        let b = Data(s.utf8)
        return le(UInt16(b.count)) + b
    }
}
