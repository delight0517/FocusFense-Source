import UIKit
import UniformTypeIdentifiers

private let kAppGroupId = "group.com.sixcleanroom.sixCleanRoom"
private let kPendingHostsFile = "pending_share_hosts.json"

class ShareViewController: UIViewController {

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = "Six Clean Room"

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "이 페이지 주소를 차단 목록에 넣습니다. 앱을 열면 자동으로 반영됩니다."
    label.numberOfLines = 0
    label.textAlignment = .center
    label.textColor = .secondaryLabel

    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("차단 목록에 추가", for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    button.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

    view.addSubview(label)
    view.addSubview(button)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -28),
      button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 20),
      button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
    ])
  }

  @objc private func saveTapped() {
    guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
          let provider = item.attachments?.first,
          provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    else {
      cancel()
      return
    }

    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] loaded, _ in
      guard let url = loaded as? URL else {
        DispatchQueue.main.async { self?.cancel() }
        return
      }
      guard let host = url.host?.lowercased() else {
        DispatchQueue.main.async { self?.cancel() }
        return
      }
      Self.appendPendingHost(host)
      DispatchQueue.main.async {
        self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
      }
    }
  }

  private func cancel() {
    let error = NSError(domain: "BlockShareExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: "No URL"])
    extensionContext?.cancelRequest(withError: error)
  }

  private static func appendPendingHost(_ host: String) {
    guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroupId) else {
      return
    }
    let fileURL = base.appendingPathComponent(kPendingHostsFile)
    var list: [String] = []
    if let data = try? Data(contentsOf: fileURL),
       let decoded = try? JSONDecoder().decode([String].self, from: data) {
      list = decoded
    }
    if !list.contains(host) {
      list.append(host)
    }
    if let data = try? JSONEncoder().encode(list) {
      try? data.write(to: fileURL)
    }
  }
}
