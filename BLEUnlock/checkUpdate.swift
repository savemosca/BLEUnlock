import Cocoa
import UserNotifications

let GITHUB_REPO = "savemosca/BLEUnlock"

private let KEY = "lastUpdateCheck"
private let INTERVAL = 24.0 * 60 * 60
private var notified = false
private var lastCheckAt = UserDefaults.standard.double(forKey: KEY)

func checkUpdate() {
    guard !notified else { return }
    let now = NSDate().timeIntervalSince1970
    guard now - lastCheckAt >= INTERVAL else { return }
    doCheckUpdate()
}

private func doCheckUpdate() {
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(GITHUB_REPO)/releases/latest")!)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let task = URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
        if let jsondata = data {
            if let json = try? JSONSerialization.jsonObject(with: jsondata) {
                if let dict = json as? [String:Any] {
                    if let version = dict["tag_name"] as? String {
                        lastCheckAt = NSDate().timeIntervalSince1970
                        UserDefaults.standard.set(lastCheckAt, forKey: KEY)
                        compareVersionsAndNotify(version)
                    }
                }
            }
        }
    })
    task.resume()
}

private func compareVersionsAndNotify(_ latestVersion: String) {
    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
        // Only a strictly newer release counts, so local or forked builds with a higher version aren't nagged.
        let latest = latestVersion.hasPrefix("v") ? String(latestVersion.dropFirst()) : latestVersion
        if latest.compare(version, options: .numeric) == .orderedDescending {
            notify()
            notified = true
        }
    }
}

private func notify() {
    let content = UNMutableNotificationContent()
    content.title = "BLEUnlock"
    content.subtitle = t("notification_update_available")
    let request = UNNotificationRequest(identifier: UPDATE_NOTIFICATION_ID, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
