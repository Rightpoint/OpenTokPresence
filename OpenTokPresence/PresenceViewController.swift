//
//  PresenceViewController.swift
//  OpenTokPresence
//
//  Created by Brian King on 2/18/16.
//  Copyright © 2016 Raizlabs. All rights reserved.
//

import Foundation
import Alamofire

class PresenceViewController: UITableViewController {

    init() {
        super.init(style: .Grouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    let presence = PresenceClient()

    var buddyList = BuddyList(users:[]) {
        didSet { tableView.reloadData() }
    }
    
    var session: OTSession?

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.registerCellClass(UserTableViewCell.self)
        tableView.registerCellClass(InviteTableViewCell.self)
        tableView.registerCellClass(EmptyTableViewCell.self)
    }

    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        register()
    }
}

extension PresenceViewController {

    func register() {
        guard session == nil else {
            return
        }
        presence.fetchPresence { response in
            if let sessionResponse = response.value {
                self.session = OTSession(apiKey: sessionResponse.apiKey, sessionId: sessionResponse.sessionId, delegate: self)
                self.presence.registerUser(UIDevice.currentDevice().name) { response in
                    if let token = response.value, let session = self.session {
                        var error: OTError?
                        session.connectWithToken(token, error: &error)
                        self.handleError(error)
                    }
                    else {
                        self.handleError(response.error)
                        self.session = nil
                    }
                }
            }
            else {
                self.handleError(response.error)
            }
        }
    }

    func presentSession(sessionInfo: SessionInfo, token: String) {
        let sessionViewController = SessionViewController()
        sessionViewController.setupSession(sessionInfo.apiKey, sessionId: sessionInfo.sessionId, token: token)
        self.navigationController?.pushViewController(sessionViewController, animated: true)
    }

    func handleError(error: NSError?) {
        if let error = error {
            print(error)
            let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .Alert)
            alert.addAction(UIAlertAction(title: "OK", style: .Default, handler: nil))
            presentViewController(alert, animated: true, completion: nil)
        }
    }
    
}

extension PresenceViewController {

    override func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return buddyList.numberOfSections()
    }

    override func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return buddyList.numberOfRowsInSection(section)
    }

    override func tableView(tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return buddyList.headerForSection(section)
    }

    override func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let row = buddyList.rowAtIndexPath(indexPath)
        switch row {
        case .Empty(let emptyDescription):
            let cell: EmptyTableViewCell = tableView.cellForIndexPath(indexPath)
            cell.textLabel?.text = emptyDescription
            return cell
        case .User(let remoteUser):
            let cell: UserTableViewCell = tableView.cellForIndexPath(indexPath)
            cell.textLabel?.text = remoteUser.name
            cell.detailTextLabel?.text = remoteUser.status.displayStatus
            return cell
        case .Invite(let remoteUser, let initiated):
            let cell: InviteTableViewCell = tableView.cellForIndexPath(indexPath)
            cell.textLabel?.text = (initiated ?
                "Waiting for \(remoteUser.name)" :
                "Invitation from \(remoteUser.name)")
            return cell
        }
    }

    override func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        let row = buddyList.rowAtIndexPath(indexPath)
        switch row {
        case .Empty(_):
            break
        case let .User(remoteUser):
            guard remoteUser.status == .Online else {
                // User is not available (in another chat)
                return
            }
            presence.initiateChat(remoteUser) { response in
                if let result = response.value {
                    self.sendMessage(Message.Invitation(identifier: remoteUser.identifier, sessionInfo: result.sessionInfo))
                    self.buddyList.sentInvite(remoteUser.identifier, invitationSessionInfo: result.sessionInfo, invitationToken: result.token)
                }
                else {
                    self.handleError(response.error!)
                }
            }
        case .Invite(let remoteUser, false):
            presence.joinChat(remoteUser, completion: { response in
                if let result = response.value {
                    self.sendMessage(Message.AcceptInvitation(identifier: remoteUser.identifier, sessionInfo: result.sessionInfo))
                    self.buddyList.clearInvite(remoteUser.identifier)
                    self.presentSession(result.sessionInfo, token: result.token)
                }
                else {
                    self.handleError(response.error!)
                }
            })
        case .Invite(let remoteUser, true):
            guard let sessionInfo = remoteUser.invitationSessionInfo else {
                fatalError("Can not cancel invite")
            }
            sendMessage(Message.CancelInvitation(identifier: remoteUser.identifier, sessionInfo: sessionInfo))

            buddyList.clearInvite(remoteUser.identifier)
            break
        }
    }

}

extension PresenceViewController : OTSessionDelegate {

    func sendMessage(message: Message) {
        guard let session = session else {
            return
        }

        let (type, body) = message.toSignal()
        var error: OTError? = nil
        session.signalWithType(type, string: body, connection: nil, error: &error)
        handleError(error)
    }

    func session(session: OTSession!, didFailWithError error: OTError!) {
        handleError(error)
    }

    func session(session: OTSession!, receivedSignalType type: String!, fromConnection connection: OTConnection!, withString string: String!) {

        guard let message = Message.fromSignal(type, withString:string, fromConnectionId:connection?.connectionId) where connection != session.connection else {
            return
        }
        switch message {
        case let .Status(identifier, status):
            buddyList.updateStatus(identifier, status: status)
        case let .Invitation(identifier, sessionInfo):
            buddyList.receivedInvite(identifier, invitationSessionInfo: sessionInfo)
        case let .AcceptInvitation(identifier, sessionInfo):
            guard let token = buddyList.tokenForInvitationSentTo(identifier) else {
                fatalError("Invitation accepted without token")
            }
            presentSession(sessionInfo, token: token)
            buddyList.clearInvite(identifier)
        case let .CancelInvitation(identifier, _):
            buddyList.clearInvite(identifier)
        case let .DeclineInvitation(identifier, _):
            buddyList.clearInvite(identifier)
        }
    }

    func session(session: OTSession!, connectionCreated connection: OTConnection!) {
        guard
            let JSON: Dictionary<String, String> = connection.data.toJSON(),
            let name = JSON[APIConstants.SessionKeys.name] else
        {
            return
        }
        buddyList.connect(connection.connectionId, name: name)
    }

    func session(session: OTSession!, connectionDestroyed connection: OTConnection!) {
        buddyList.disconnect(connection.connectionId)
    }

    func session(session: OTSession!, streamCreated stream: OTStream!) {    }
    func session(session: OTSession!, streamDestroyed stream: OTStream!) {    }
    func sessionDidConnect(session: OTSession!) {    }
    func sessionDidDisconnect(session: OTSession!) {    }
    func sessionDidBeginReconnecting(session: OTSession!) {    }
    func sessionDidReconnect(session: OTSession!) {    }

}
