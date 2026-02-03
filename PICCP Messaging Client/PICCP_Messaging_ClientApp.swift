//
//  PICCP_Messaging_ClientApp.swift
//  PICCP Messaging Client
//
//  Created by Luiz Fernando Widmer Neto on 27/12/25.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct PICCP_Messaging_ClientApp: App {
    init() {
        #if os(iOS)
        let tableAppearance = UITableView.appearance()
        tableAppearance.backgroundColor = .clear

        let tableCellAppearance = UITableViewCell.appearance()
        tableCellAppearance.backgroundColor = .clear

        let headerFooterAppearance = UITableViewHeaderFooterView.appearance()
        headerFooterAppearance.contentView.backgroundColor = .clear
        headerFooterAppearance.backgroundView = UIView()
        headerFooterAppearance.backgroundView?.backgroundColor = .clear

        let collectionAppearance = UICollectionView.appearance()
        collectionAppearance.backgroundColor = .clear

        let scrollAppearance = UIScrollView.appearance()
        scrollAppearance.backgroundColor = .clear

        let textFieldAppearance = UITextField.appearance()
        textFieldAppearance.backgroundColor = .clear
        textFieldAppearance.borderStyle = .none

        let textViewAppearance = UITextView.appearance()
        textViewAppearance.backgroundColor = .clear

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        UIView.appearance(whenContainedInInstancesOf: [UISplitViewController.self]).backgroundColor = .clear
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
