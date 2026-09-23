//
//  InstallAppDialog.swift
//  SideStore
//
//  Created by Magesh K on 8/2/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

@MainActor
public enum InstallAppDialog {
    
    public static func presentSourceSelection(
        from presentingVC: UIViewController,
        barButtonItem: UIBarButtonItem? = nil,
        onChooseFiles: @escaping () -> Void,
        onConfirm: @escaping (URL) -> Void
    ) {
        #if !os(tvOS)
        let alertController = UIAlertController(
            title: NSLocalizedString("Install App", comment: ""),
            message: nil,
            preferredStyle: .actionSheet
        )
        if let popover = alertController.popoverPresentationController {
            popover.barButtonItem = barButtonItem
        }
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Choose from Files", comment: ""), style: .default) { _ in
            onChooseFiles()
        })
        #else
        let alertController = UIAlertController(
            title: NSLocalizedString("Install App", comment: ""),
            message: NSLocalizedString("Choose an installation method:", comment: ""),
            preferredStyle: .alert
        )
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Upload via Web", comment: ""), style: .default) { _ in
            onChooseFiles()
        })
        #endif
        
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Install from URL", comment: ""), style: .default) { _ in
            self.presentURLInputDialog(from: presentingVC, onConfirm: onConfirm)
        })
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        
        presentingVC.present(alertController, animated: true)
    }
    
    private static func presentURLInputDialog(
        from presentingVC: UIViewController,
        onConfirm: @escaping (URL) -> Void
    ) {
        let alert = UIAlertController(
            title: NSLocalizedString("Install from URL", comment: ""),
            message: NSLocalizedString("Enter the URL of the .ipa file to install.", comment: ""),
            preferredStyle: .alert
        )
        
        alert.addTextField { textField in
            textField.placeholder = "https://example.com/app.ipa"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.clearButtonMode = .whileEditing
        }
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Continue", comment: ""), style: .default) { _ in
            guard let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https") else {
                let errorAlert = UIAlertController(
                    title: NSLocalizedString("Invalid URL", comment: ""),
                    message: NSLocalizedString("Please enter a valid HTTP or HTTPS URL.", comment: ""),
                    preferredStyle: .alert
                )
                errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                presentingVC.present(errorAlert, animated: true)
                return
            }
            
            self.present(ipaURL: url, from: presentingVC) {
                onConfirm(url)
            }
        })
        
        presentingVC.present(alert, animated: true)
    }
    
    public static func present(
        ipaURL: URL,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let rootVC = presentingViewController ?? UIApplication.shared.topViewController()
        guard let presentingVC = rootVC else {
            onCancel()
            return
        }
        
        let message: String
        if ipaURL.isFileURL {
            let appName = ipaURL.deletingPathExtension().lastPathComponent
            message = String(format: NSLocalizedString("Do you want to continue? This will install \"%@\".", comment: ""), appName)
        } else {
            message = String(format: NSLocalizedString("Do you want to continue? This will download and install from:\n%@", comment: ""), ipaURL.absoluteString)
        }
        
        let alert = UIAlertController(
            title: NSLocalizedString("Install App", comment: ""),
            message: message,
            preferredStyle: .alert
        )
        
        let installAction = UIAlertAction(title: NSLocalizedString("Install", comment: ""), style: .default) { _ in
            onConfirm()
        }
        
        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            onCancel()
        }
        
        alert.addAction(installAction)
        alert.addAction(cancelAction)
        
        presentingVC.present(alert, animated: true)
    }
}
