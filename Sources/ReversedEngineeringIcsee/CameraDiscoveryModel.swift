import Foundation
import Observation

@MainActor @Observable
final class CameraDiscoveryModel {
    private(set) var isScanning = false
    private(set) var hasSearched = false
    private(set) var devices: [DiscoveredCamera] = []
    private(set) var error: String?
    private var task: Task<Void, Never>?

    func start() {
        cancel()
        isScanning = true
        hasSearched = false
        devices = []
        error = nil
        task = Task {
            do {
                let found = try await CameraDiscovery.scan()
                guard !Task.isCancelled else { return }
                devices = found
                hasSearched = true
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isScanning = false
            task = nil
        }
    }
    func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
    }
}
