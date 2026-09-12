import Foundation
@preconcurrency import MultipeerConnectivity
import PaperCore

/// The other devices in the room, reached directly.
///
/// iCloud Drive carries the library between devices, but it takes its time —
/// a 20 MB PDF re-uploaded for one highlight is a ten-second wait — and it
/// cannot be hurried. Two devices on the same network do not have to wait for
/// it: a change is a few hundred bytes, and Multipeer Connectivity delivers
/// it in the time it takes to look up. What arrives this way is applied to
/// the open page and never written to disk; the disk copy follows through
/// the folder, and finds nothing left to do.
///
/// Peers only join when they advertise the same library ID — the one in the
/// folder's manifest — so two people with the app on one Wi-Fi stay apart.
public final class NearbySync: NSObject, @unchecked Sendable {
    public static let shared = NearbySync()

    /// One change, as it travels.
    public struct Envelope: Codable, Sendable {
        public var kind: String
        public var paperID: UUID
        public var page: Int?
        public var device: String
        public var data: Data

        public init(kind: String, paperID: UUID, page: Int? = nil, device: String, data: Data) {
            self.kind = kind
            self.paperID = paperID
            self.page = page
            self.device = device
            self.data = data
        }
    }

    /// Posted on the main queue with `userInfo["envelope"]` an `Envelope`.
    public static let messageNotification = Notification.Name("PaperTimeNearbyMessage")
    /// Posted on the main queue when a peer connects or leaves.
    public static let peersNotification = Notification.Name("PaperTimeNearbyPeers")

    /// Names of the devices connected right now.
    public private(set) var connectedPeers: [String] = []

    private static let serviceType = "papertime-sync"
    private let peerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var libraryID = ""
    private let queue = DispatchQueue(label: "com.imtaeheon.PaperTime.NearbySync")

    override private init() {
        // Unique even when two devices share a name, and short enough for
        // the framework's limit on display names.
        peerID = MCPeerID(displayName: String(DeviceIdentity.current.prefix(60)))
        super.init()
    }

    public func start(libraryID: String) {
        queue.async { [self] in
            stopOnQueue()
            self.libraryID = libraryID
            let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self
            self.session = session
            let advertiser = MCNearbyServiceAdvertiser(
                peer: peerID, discoveryInfo: ["library": libraryID], serviceType: Self.serviceType
            )
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
            let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
        }
    }

    public func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        publishPeers([])
    }

    /// Hands a change to every connected device. Nothing is queued for
    /// devices that are not here: the folder will bring it to them.
    public func send(_ envelope: Envelope) {
        queue.async { [self] in
            guard let session, !session.connectedPeers.isEmpty,
                  let data = try? JSONEncoder().encode(envelope) else { return }
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }
    }

    private func publishPeers(_ names: [String]) {
        DispatchQueue.main.async { [self] in
            connectedPeers = names
            NotificationCenter.default.post(name: Self.peersNotification, object: self)
        }
    }
}

extension NearbySync: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        queue.async { [self] in
            guard info?["library"] == libraryID, let session else { return }
            // Both sides see each other; one invitation is enough, so the
            // lesser name extends it and the greater one accepts.
            guard peerID.displayName < peer.displayName else { return }
            browser.invitePeer(peer, to: session, withContext: Data(libraryID.utf8), timeout: 20)
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}

extension NearbySync: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID,
        withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        queue.async { [self] in
            let theirs = context.map { String(decoding: $0, as: UTF8.self) }
            let accepted = theirs == libraryID && session != nil
            invitationHandler(accepted, accepted ? session : nil)
        }
    }
}

extension NearbySync: MCSessionDelegate {
    public func session(_ session: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        publishPeers(session.connectedPeers.map(\.displayName))
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.messageNotification, object: nil, userInfo: ["envelope": envelope]
            )
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer peer: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peer: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peer: MCPeerID, at url: URL?, withError error: (any Error)?) {}
}
