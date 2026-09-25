// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Arveil';

  @override
  String get navChats => 'Chats';

  @override
  String get navContacts => 'Contacts';

  @override
  String get navSettings => 'Settings';

  @override
  String get profileClose => 'Close profile';

  @override
  String get profileStateUnreadable =>
      'The profile\'s state could not be read.';

  @override
  String get profileReadAgain => 'Read again';

  @override
  String get enrollBack => 'Back to setup';

  @override
  String get operationInProgress => 'Operation in progress';

  @override
  String get operationInProgressDetail =>
      'Operation in progress. Confirmed progress stays saved in the profile.';

  @override
  String get welcomeTitle => 'Your identity, on this device';

  @override
  String get welcomeBody =>
      'Open your profile, or prepare a new one to join with an invitation.';

  @override
  String get welcomeKeyNote =>
      'The profile is encrypted with a key kept in this device\'s secure storage. If that key is lost, the local history cannot be recovered.';

  @override
  String get profileOpen => 'Open profile';

  @override
  String get enrollTitleRetry => 'Resume your setup';

  @override
  String get enrollTitle => 'Join your space';

  @override
  String get enrollBodyRetry =>
      'Your progress is saved. Use the same invitation to continue with your identity.';

  @override
  String get enrollBody =>
      'Ask the administrator for the server details and an invitation. Your identity is created on this device when you continue.';

  @override
  String get setupRedeeming => 'Waiting to confirm the invitation.';

  @override
  String get setupRedeemed =>
      'Invitation accepted. The configuration has not arrived yet.';

  @override
  String get setupPublishing =>
      'Configuration received. The mailbox and messaging keys are not finished yet.';

  @override
  String get setupIdentityReady => 'Your local identity is already created.';

  @override
  String get setupNew => 'Ready to create your identity.';

  @override
  String get enrollRelayLabel => 'Server details';

  @override
  String get enrollRelayInvalid => 'Paste the complete server details.';

  @override
  String get enrollInviteLabel => 'Invitation';

  @override
  String get enrollInviteHelper =>
      'It is not stored. Keep it until setup is complete.';

  @override
  String get enrollInviteInvalid =>
      'The invitation must contain 64 hexadecimal characters.';

  @override
  String get enrollRetry => 'Retry setup';

  @override
  String get enrollSubmit => 'Create identity and join';

  @override
  String get enrollPair => 'Link with my other device';

  @override
  String get enrollRestore => 'Restore from a kit';

  @override
  String get kitReminderNever =>
      'Save your identity kit. Without a kit or another linked device, losing this device means losing your identity.';

  @override
  String get kitReminderStale =>
      'Your devices changed after you saved the kit. Save a new one so that a recovery knows about them.';

  @override
  String get kitSave => 'Save kit';

  @override
  String get later => 'Later';

  @override
  String get recoveryRollbackWarning =>
      'The server knew a manifest older than your kit. Check the revocations with a contact or a surviving device before trusting its state.';

  @override
  String get manageDevices => 'Manage devices';

  @override
  String get encryptedHistory => 'Encrypted history';

  @override
  String get linkedDeviceKitNote =>
      'This device is linked. The identity kit is exported from the administration device.';

  @override
  String get errorSecureStorageUnavailable =>
      'The device\'s secure storage is not available. Unlock the device and check the permission to use secure storage.';

  @override
  String get errorProfileKeyMissing =>
      'This profile\'s key is missing, so its local history cannot be opened. Keep the profile until the key is recovered.';

  @override
  String get errorEnrollmentUnreadable =>
      'Setup finished, but the profile could not be read. Close it and open it again.';

  @override
  String get errorOperationUnreadable =>
      'The operation finished, but the profile could not be read. Close it and open it again.';

  @override
  String get pairingConfirmationStarted =>
      'Confirmation has already started. Resume finishing the link.';

  @override
  String get errorBadKey => 'The profile key is not in a valid format.';

  @override
  String get errorNoRandomness => 'The system could not generate a secure key.';

  @override
  String get errorProfileInUse =>
      'The profile is open in another session. Close it and try again.';

  @override
  String get errorProfileClosing => 'The profile is still closing. Try again.';

  @override
  String get errorProfileTooNew =>
      'A newer version of Arveil saved this profile. Update the app to open it; the profile has not been changed.';

  @override
  String get errorProfileUnusable =>
      'The profile could not be decrypted. Keep the data and check its key.';

  @override
  String get errorProfileIo =>
      'The profile could not be accessed. Check the device\'s storage space and permissions.';

  @override
  String get errorSecureStoragePrepare =>
      'The profile\'s secure storage could not be prepared. Try again.';

  @override
  String get errorTransport =>
      'Could not connect to the server. Check the connection and follow the pending operation\'s instructions.';

  @override
  String get errorDomain =>
      'Check the details and whether the operation is still valid. Keep the profile; do not start a different setup to retry.';

  @override
  String get errorProtocol =>
      'The server did not accept the operation. Check the details with its administrator; a recovery may need a more recent kit.';

  @override
  String get errorBusy =>
      'Another operation is in progress. Wait and try again.';

  @override
  String get errorStorage =>
      'Progress could not be saved. Check storage and try again.';

  @override
  String get errorInterrupted =>
      'The operation was interrupted. You can try again.';

  @override
  String get errorUnknown =>
      'The operation could not be completed. Close the profile and open it again.';

  @override
  String get syncWhenNow => 'just now';

  @override
  String syncWhenMinutes(int minutes) {
    return '$minutes min ago';
  }

  @override
  String syncWhenTime(String time) {
    return 'at $time';
  }

  @override
  String syncLastSuffix(String when) {
    return ' · last synced $when';
  }

  @override
  String get syncNever => 'Not synced yet';

  @override
  String get syncSyncing => 'Syncing…';

  @override
  String syncSynced(String when) {
    return 'Synced $when';
  }

  @override
  String syncOffline(String last) {
    return 'No connection to your server$last';
  }

  @override
  String syncRefused(String last) {
    return 'The server refused to sync$last';
  }

  @override
  String get chatErrorHistory =>
      'The local history could not be read. Keep the profile and open it again.';

  @override
  String get chatErrorConversation =>
      'This conversation could not be read. Try again.';

  @override
  String get chatErrorOlder =>
      'Earlier messages could not be read. You can retry.';

  @override
  String get chatSyncPending =>
      'Sync pending. You can read and write offline; use Sync to retry.';

  @override
  String get chatSyncRefused =>
      'The server did not accept the sync. Your messages stay saved on this device; check the server details with whoever runs it.';

  @override
  String get chatMessageTooLong => 'Write a message of up to 32 KiB.';

  @override
  String get chatSavedRetrySync =>
      'Message saved. Retry syncing; do not send it again.';

  @override
  String get chatSaveUnconfirmed =>
      'Saving was not confirmed. Keep the draft and check the history before retrying.';

  @override
  String get chatFileSaveUnconfirmed =>
      'Saving the file was not confirmed. Check the history before attaching it again.';

  @override
  String get chatTransferIncomplete =>
      'The operation did not complete. Check the file\'s state: resume its transfer, or sync if it is ready.';

  @override
  String get chatCancelFailed =>
      'Could not cancel. The transfer may have finished; check its state.';

  @override
  String get chatCreatedSyncPending =>
      'Conversation saved. Sync to finish sending the invitation; do not create it again.';

  @override
  String get chatCreateUnconfirmed =>
      'Creation was not confirmed. Check the routes, the connection and that your contacts have keys available. Check the list before retrying.';

  @override
  String get dialogSaveHistory => 'Save encrypted history';

  @override
  String get dialogOpenHistory => 'Open encrypted history';

  @override
  String get dialogSaveKit => 'Save encrypted identity kit';

  @override
  String get dialogOpenKit => 'Open identity kit';

  @override
  String get kitTooLarge => 'The kit exceeds the 4 MiB size limit.';

  @override
  String get dialogChooseFile => 'Choose file';

  @override
  String get dialogSaveFileCopy => 'Save a copy of the file';

  @override
  String get recoveryIncomplete =>
      'Choose the kit, enter its key and the server details, and confirm the consequences of the recovery.';

  @override
  String get kitTitle => 'Identity kit';

  @override
  String get kitExplanation =>
      'The kit recovers your identity, not the history or the state of groups. Keep the encrypted file and its key apart; together they allow taking control of the identity.';

  @override
  String get kitRevealSavedKey => 'Show the saved kit\'s key';

  @override
  String get kitSavedKeyNow =>
      'File saved. Now keep this key separately, for example in your password manager. Arveil does not keep it.';

  @override
  String get kitKeyDisappears =>
      'The key disappears when you leave this screen or switch apps. If you lose it, create a new kit.';

  @override
  String get kitKeySavedConfirm => 'I have saved the key separately';

  @override
  String get kitSavedByConfirmation =>
      'Kit and key saved, as you confirmed. Export a new one after changing your devices.';

  @override
  String get kitDeferredWarning =>
      'Kit postponed: losing the administration device without a kit may prevent recovering your identity.';

  @override
  String get kitSaveEncrypted => 'Save encrypted kit';

  @override
  String get kitPostpone => 'Postpone the kit';

  @override
  String get recoveryTitle => 'Recover my identity';

  @override
  String get recoveryExplanation =>
      'Use the most recent kit and its key. This recovery creates a new administration device and revokes the earlier devices listed in the manifest. The history is not recovered; you will have to join groups again.';

  @override
  String get recoveryRelayLabel => 'Original server details';

  @override
  String get recoveryChooseKit => 'Choose encrypted kit';

  @override
  String get recoveryKitChosen => 'Kit chosen: change file';

  @override
  String get recoveryKitKey => 'Kit key';

  @override
  String get recoveryConsent =>
      'I understand that the earlier devices will be revoked and their history will not be recovered.';

  @override
  String get recoveryRestore => 'Restore identity and revoke devices';

  @override
  String get recoveryResumeTitle => 'Continue the recovery';

  @override
  String get recoveryResumeBody =>
      'The identity and the new device\'s keys are saved. The server may already have accepted revoking the earlier ones. Resume this same operation; you do not need to open the kit again or create another profile.';

  @override
  String get recoveryResume => 'Resume recovery';

  @override
  String get keyPackagesTitle => 'Keys for new groups';

  @override
  String get keyPackagesExplanation =>
      'This device publishes single-use keys so that other people can start conversations with it. Existing conversations keep their own keys.';

  @override
  String get keyPackagesUnknown => 'Availability not checked';

  @override
  String get keyPackagesEmpty => 'Last check: no keys available';

  @override
  String get keyPackagesLow => 'Last check: few keys left';

  @override
  String get keyPackagesReady => 'Last check: keys available';

  @override
  String keyPackagesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count keys available according to the server.',
      one: '1 key available according to the server.',
    );
    return '$_temp0';
  }

  @override
  String keyPackagesCheckedAt(String date, String time) {
    return 'Checked on $date at $time. It may change when someone uses a key.';
  }

  @override
  String get keyPackagesNoneWarning =>
      'Other devices cannot start new conversations with this device until keys are available.';

  @override
  String get keyPackagesReplenishSoon =>
      'Replenish the keys before they run out.';

  @override
  String get keyPackagesPending =>
      'A publication is waiting for confirmation. Resuming sends the same saved batch; it does not regenerate those keys.';

  @override
  String get keyPackagesUnavailable =>
      'Could not update the availability. The last saved figure does not confirm the current state.';

  @override
  String get keyPackagesCheck => 'Check availability';

  @override
  String get keyPackagesResume => 'Resume publishing keys';

  @override
  String get keyPackagesReplenish => 'Replenish keys';

  @override
  String get attachmentSavedPending => 'Saved on this device · waiting to send';

  @override
  String get attachmentDownloadInterrupted => 'Download interrupted';

  @override
  String get attachmentDownloadAwaiting => 'Download waiting for your approval';

  @override
  String get attachmentTransferring => 'Transferring…';

  @override
  String get attachmentTransferInterrupted =>
      'Transfer interrupted · you can resume';

  @override
  String get attachmentDownloaded =>
      'Downloaded and verified · encrypted private copy';

  @override
  String get deliveryNoRecipients => 'Saved locally · no recipients available';

  @override
  String get deliveryAccepted =>
      'Accepted by the server · not confirmed as read';

  @override
  String get deliveryRejected => 'A mailbox rejected the message';

  @override
  String get deliveryExpired => 'Delivery expired or unknown';

  @override
  String get attachmentReady => 'File ready · sending when you sync';

  @override
  String get attachmentCancelled =>
      'Transfer cancelled · incomplete copy removed';

  @override
  String get attachmentUnavailable =>
      'File unavailable or access refused. You can retry or ask for another copy.';

  @override
  String get attachmentExpiredOnRelay =>
      'The file expired on the server. Ask for it to be sent again.';

  @override
  String get attachmentUnverified =>
      'The file could not be verified. It cannot be saved outside Arveil.';

  @override
  String get attachmentLegacy =>
      'Attachment from an earlier version; it is not available on this screen.';

  @override
  String get attachmentSendResume => 'Send / resume';

  @override
  String get attachmentResumeDownload => 'Resume download';

  @override
  String get attachmentDownload => 'Download';

  @override
  String get attachmentCancel => 'Cancel transfer';

  @override
  String get attachmentSaveCopy => 'Save a copy…';

  @override
  String get devicesOperationFailed =>
      'The operation could not be completed. Check the saved state and sync again.';

  @override
  String get devicesReadFailed =>
      'Could not read the state of the devices. Try again.';

  @override
  String get devicesRevokeTitle => 'Revoke this device?';

  @override
  String get devicesRevokeCheckId =>
      'Check the full identifier on the other device before continuing.';

  @override
  String get devicesRevokeConsequences =>
      'Revoking is permanent. It is saved here and published when you connect. The server blocks the device once it accepts the change; conversations also need to remove it from their group. It does not erase the copies or history the device already has.';

  @override
  String get cancel => 'Cancel';

  @override
  String get devicesRevokeConfirm => 'Revoke permanently';

  @override
  String get devicesTitle => 'Devices';

  @override
  String get devicesKnownState =>
      'State known to this profile. Being authorized does not mean a device is connected.';

  @override
  String get devicesSync => 'Sync devices';

  @override
  String get devicesReadLocal => 'Read the local state again';

  @override
  String get devicesAdministrator => 'This profile can manage its devices.';

  @override
  String get devicesLinked =>
      'This device is linked. Revoke devices from the administration profile.';

  @override
  String devicesManifestVersion(String sequence) {
    return 'Local manifest version: $sequence';
  }

  @override
  String devicesPartialInventory(int active, int revoked) {
    return 'Partial inventory: the manifest includes $active authorized and $revoked revoked credentials whose device identifiers this profile does not know. Use the administration device to manage them.';
  }

  @override
  String get devicesThis => 'This device';

  @override
  String get devicesLinkedDevice => 'Linked device';

  @override
  String get devicesRevokedLocally => 'Revoked according to the local state';

  @override
  String get devicesNotRevoked => 'Not recorded as revoked in this profile';

  @override
  String get devicesRevocationAccepted => 'Revocation accepted by the server';

  @override
  String get devicesRevocationPending =>
      'Revocation waiting to be published to the server';

  @override
  String devicesGroupsWaiting(int count) {
    return 'Local conversations still to remove it: $count';
  }

  @override
  String get devicesGroupsWaitingHelp =>
      'Sync to receive the changes. Removing it is up to the device that coordinates the group\'s changes; meanwhile, sending stays blocked for those who know about the revocation.';

  @override
  String devicesNoticesPending(int count) {
    return 'Notices waiting to be published: $count';
  }

  @override
  String devicesNoticesUnconfirmed(int count) {
    return 'Notices refused or expired without confirmation: $count. Check with the other participants.';
  }

  @override
  String devicesNoticesWithoutRoute(int count) {
    return 'Notices that could not be prepared for lack of a route: $count. The routes need checking; they are not resent automatically.';
  }

  @override
  String get devicesAcceptanceCaveat =>
      'The server accepting it does not confirm that the other devices received the notice.';

  @override
  String get devicesRevoke => 'Revoke device';

  @override
  String get pairingTitle => 'Link this device';

  @override
  String get pairingExplanation =>
      'Use your administration device to authorize this profile. Linking keeps your identity; it does not copy the earlier history.';

  @override
  String get pairingRelayLabel => 'Server details';

  @override
  String get pairingRelayInvalid => 'Paste the complete server details.';

  @override
  String get pairingGenerate => 'Generate a link code';

  @override
  String get pairingConfirmationSaved =>
      'The confirmation is saved. The setup on the server still has to finish.';

  @override
  String get pairingResumeFinish => 'Resume finishing';

  @override
  String get pairingExpired =>
      'This session has expired. Cancel it and generate a new code.';

  @override
  String get pairingComparisonCode => 'Comparison code';

  @override
  String get pairingCompareHelp =>
      'Check both screens. Enter here the code the administration device shows. If they differ, cancel.';

  @override
  String get pairingOtherCode => 'The other device\'s code';

  @override
  String get pairingConfirmComparison => 'Confirm comparison';

  @override
  String get pairingShareCode =>
      'On the administration device, open “Link another device” and paste this code through a private channel.';

  @override
  String pairingExpiresIn(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: 'Expires in $seconds seconds.',
      one: 'Expires in 1 second.',
    );
    return '$_temp0';
  }

  @override
  String get pairingWaiting => 'Waiting for the administration device…';

  @override
  String get pairingWaitInterrupted =>
      'The wait was interrupted. Cancel this session and generate another code; a comparison already received is kept when you reopen.';

  @override
  String get pairingCancel => 'Cancel linking';

  @override
  String get pairingCancelNote =>
      'Cancelling stops this local enrollment. If the administration device already issued an authorization, it is not revoked.';

  @override
  String get pairingOtherTitle => 'Link another device';

  @override
  String get pairingAdminCompare =>
      'Compare this code with the new device\'s and enter it there to finish.';

  @override
  String get pairingAuthorizationIssued =>
      'The authorization has been issued. Closing this comparison does not revoke it. If you do not recognize the request, revoke that device from the CLI.';

  @override
  String get pairingCloseComparison => 'Close comparison';

  @override
  String get pairingPasteOwnCode =>
      'Only paste the code of a device of yours that you have in front of you. This step issues its authorization.';

  @override
  String get pairingCodeLabel => 'Link code';

  @override
  String get pairingCodeInvalid => 'Paste the complete link code.';

  @override
  String get pairingAuthorize => 'Authorize and compare';

  @override
  String get pairingKeepOpen =>
      'Keep both devices open during the wait, which lasts up to 90 seconds.';

  @override
  String get archiveFailed =>
      'The operation could not be completed. Check the file, its key and that it belongs to your identity. At most 10,000 records; exports of up to 48 MiB of content and imports of files up to 64 MiB.';

  @override
  String archiveSaved(int records, int files, int missing) {
    return 'File saved: $records records, $files attachments with a copy, $missing without.';
  }

  @override
  String archiveImported(int imported, int duplicates) {
    return '$imported records imported; $duplicates already present, kept unchanged.';
  }

  @override
  String get archiveFileSaved => 'Attachment copy saved to the chosen place.';

  @override
  String get archiveTitle => 'Encrypted history';

  @override
  String get archiveExplanation =>
      'The encrypted history recovers the available messages and attachments, without recovering the identity or group sessions. Restore your identity with its kit first if you lost the device.';

  @override
  String get archiveKeepApart =>
      'Keep the file and its key apart. Together they allow reading this copy of the past. Pending attachments are not downloaded; older CLI files may appear without a copy.';

  @override
  String get archiveConsent =>
      'I understand that this copy allows reading the history';

  @override
  String get archiveSave => 'Save encrypted history';

  @override
  String get archiveRevealKey => 'Show the saved file\'s key';

  @override
  String get archiveKeyNote =>
      'Keep this key separately. It disappears when you leave or switch apps; Arveil does not keep it.';

  @override
  String get archiveKeySaved => 'I have saved the key';

  @override
  String get archiveImportTitle => 'Import history';

  @override
  String get archiveImportNote =>
      'Only a file from this identity is accepted. The records are added as read-only history: they are not resent and give no access to groups. An imported file does not prove who wrote its messages.';

  @override
  String get archiveChooseFile => 'Choose encrypted file';

  @override
  String get archiveFileChosen => 'File chosen; change';

  @override
  String get archiveKeyLabel => 'File key';

  @override
  String get archiveImport => 'Import as history';

  @override
  String get archiveImportedTitle => 'Imported history · read-only';

  @override
  String get archiveEmpty => 'No records imported yet.';

  @override
  String archiveEntryOutgoing(String group) {
    return 'Group $group · Outgoing';
  }

  @override
  String archiveEntryIncoming(String group) {
    return 'Group $group · Incoming';
  }

  @override
  String archiveEntrySender(String header, String sender) {
    return '$header · $sender, according to the file';
  }

  @override
  String get archiveNoFileCopy => 'No copy of the attachment in this file';

  @override
  String get archiveSaveFileCopy => 'Save a copy of the attachment';

  @override
  String get archiveOlder => 'See earlier records';

  @override
  String get archiveBackToStart => 'Back to the start of the history';

  @override
  String get contactsReadFailed => 'Could not read the contacts. Try again.';

  @override
  String get contactsChoose => 'Choose contacts';

  @override
  String get contactsTitle => 'Contacts';

  @override
  String get contactAdd => 'Add contact';

  @override
  String get retry => 'Retry';

  @override
  String get contactsNamesLocal =>
      'Names are local. Check the identity by comparing the safety number through another channel.';

  @override
  String get contactsDeviceLimit =>
      'Saved devices not recorded as revoked will be included. Maximum: 16 devices.';

  @override
  String get contactsEmpty => 'You have no saved contacts yet.';

  @override
  String get verified => 'Verified';

  @override
  String get unverified => 'Unverified';

  @override
  String get contactNeedsRoute => 'Add a route to start talking';

  @override
  String contactDevicesAvailable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count devices available',
      one: '1 device available',
    );
    return '$_temp0';
  }

  @override
  String get contactsTooMany => 'Select at most 16 devices.';

  @override
  String contactsUse(int count) {
    return 'Use contacts ($count)';
  }

  @override
  String get contactRouteInvalid =>
      'Check the contact\'s complete route. It must come from another device.';

  @override
  String get contactSaved => 'Contact saved in this profile.';

  @override
  String get contactSaveFailed =>
      'Could not save. Check the name and the comparison; keep the profile and try again.';

  @override
  String get contactVerifiedNotice => 'Identity verified.';

  @override
  String get contactVerifyFailed =>
      'The comparison could not be confirmed. Reopen the contact and compare the number again.';

  @override
  String get contactDetails => 'Contact details';

  @override
  String get contactNameLabel => 'Local name (optional)';

  @override
  String get contactNameHelper =>
      'Only saved in this profile. It does not verify the identity.';

  @override
  String get contactRouteLabel => 'Contact route';

  @override
  String get contactRouteHelper =>
      'Ask the person you want to add for their route on this server.';

  @override
  String get contactPrepare => 'Prepare contact';

  @override
  String contactIdentity(String identity) {
    return 'Identity $identity';
  }

  @override
  String get contactCompareHelp =>
      'Compare this number with the other person through another channel. The local name does not replace this check.';

  @override
  String get contactCompared =>
      'We compared the number through another channel and it matches.';

  @override
  String get contactVerify => 'Verify contact';

  @override
  String contactRoutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count saved routes',
      one: '1 saved route',
    );
    return '$_temp0';
  }

  @override
  String contactDevice(String id) {
    return 'Device $id';
  }

  @override
  String contactDeviceRevoked(String id) {
    return 'Device $id · Revoked';
  }

  @override
  String get contactUpdateRoute =>
      'To add or update a route, go back to Add contact. Check that the identity matches and keep the name you want to use.';

  @override
  String get contactSave => 'Save contact';

  @override
  String get contactSaveName => 'Save name';

  @override
  String numericDate(String day, String month, String year) {
    return '$month/$day/$year';
  }

  @override
  String noticeAdded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'added $count devices',
      one: 'added a device',
    );
    return '$_temp0';
  }

  @override
  String noticeRemoved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'removed $count devices',
      one: 'removed a device',
    );
    return '$_temp0';
  }

  @override
  String noticeBoth(String first, String second) {
    return '$first and $second';
  }

  @override
  String noticeSentence(String who, String change) {
    return '$who $change.';
  }

  @override
  String get noticeSomeone => 'A contact';

  @override
  String previewAttachment(String name) {
    return 'Attachment: $name';
  }

  @override
  String previewOwn(String text) {
    return 'You: $text';
  }

  @override
  String get conversationEvent => 'Conversation event';

  @override
  String conversationFallback(String id) {
    return 'Conversation $id';
  }

  @override
  String get sendFile => 'Send file';

  @override
  String attachConfirm(String name, String size, String conversation) {
    return '$name\n$size\n\nConversation: $conversation\n\nAn encrypted private copy is kept to complete or resume sending.';
  }

  @override
  String get fileReadFailed =>
      'Could not read the file. Choose an accessible one smaller than 25 MiB.';

  @override
  String get exportTitle => 'Save a copy outside Arveil';

  @override
  String get exportWarning =>
      'The copy will be outside Arveil\'s encrypted profile and may end up in the destination\'s backups. Choose where to save it.';

  @override
  String get exportChoose => 'Choose destination';

  @override
  String get exportSaved => 'Copy saved to the chosen place.';

  @override
  String get exportFailed =>
      'Could not save the copy. The private file is kept; try again.';

  @override
  String get participants => 'Participants';

  @override
  String get participantsYou => 'Your identity';

  @override
  String identityDevice(String identity, String device) {
    return 'Identity $identity · device $device';
  }

  @override
  String participantDevice(String identity, String device) {
    return '$identity · device $device';
  }

  @override
  String get revoked => 'Revoked';

  @override
  String get ownDevice => 'Own device';

  @override
  String get close => 'Close';

  @override
  String get ownRouteTitle => 'Your contact route';

  @override
  String get ownRouteShare =>
      'Share it only with the people you want to be able to write to this device. Then compare the safety number together through another channel.';

  @override
  String get ownRouteCopy => 'Copy route';

  @override
  String get ownRouteFailed => 'Could not get this device\'s route.';

  @override
  String get backToConversations => 'Back to conversations';

  @override
  String get myRoute => 'My route';

  @override
  String get newConversation => 'New conversation';

  @override
  String get sync => 'Sync';

  @override
  String get syncing => 'Syncing';

  @override
  String get chooseConversation => 'Choose a conversation to read it.';

  @override
  String get conversationsEmpty => 'No saved conversations yet.';

  @override
  String get conversationsEmptyHelp =>
      'Create one with a contact route, or sync to receive an invitation.';

  @override
  String conversationCounts(int devices, int messages) {
    String _temp0 = intl.Intl.pluralLogic(
      devices,
      locale: localeName,
      other: '$devices devices',
      one: '1 device',
    );
    String _temp1 = intl.Intl.pluralLogic(
      messages,
      locale: localeName,
      other: '$messages messages',
      one: '1 message',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String unreadMessages(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count unread messages',
      one: '1 unread message',
    );
    return '$_temp0';
  }

  @override
  String get savingMessage => 'Saving message';

  @override
  String localHistory(String id) {
    return 'Local history · $id';
  }

  @override
  String get firstMessage => 'Write the first message.';

  @override
  String get reading => 'Reading…';

  @override
  String get loadOlder => 'Load earlier';

  @override
  String get attachFile => 'Attach file';

  @override
  String get messageHint => 'Message';

  @override
  String get send => 'Send';

  @override
  String get noticeSigned => 'The change is signed by their verified identity.';

  @override
  String get noticeCompare =>
      'Compare their safety number if you did not expect this change.';

  @override
  String get legacyAttachment => 'Attachment (available from the CLI)';

  @override
  String get sentFromOtherDevice => 'Sent from another of your devices';

  @override
  String get receivedHere => 'Received on this device';

  @override
  String get deliveryPending => 'Saved locally · waiting to send';

  @override
  String get newConversationRoutesInvalid =>
      'Check the complete routes: between one and sixteen different devices, not including this one.';

  @override
  String get newConversationChooseContacts => 'Choose saved contacts';

  @override
  String get newConversationRoutesHelp =>
      'Or use a new route. Ask your contacts for their route on this server. Paste one route per line and compare the safety number with each person through another channel before creating the group.';

  @override
  String get newConversationRoutesLabel => 'Contact routes';

  @override
  String get newConversationPrepare => 'Prepare comparison';

  @override
  String get newConversationCompared =>
      'We compared all the numbers through another channel and they match.';

  @override
  String get newConversationCreate => 'Create conversation';

  @override
  String get deliveryNone =>
      'Saved only on this device: no recipients available';

  @override
  String get deliveryWaiting => 'Waiting to send';

  @override
  String get deliveryAcceptedShort => 'Accepted by the server';

  @override
  String safetyNumberLabel(String groups) {
    return 'Safety number: $groups';
  }
}
