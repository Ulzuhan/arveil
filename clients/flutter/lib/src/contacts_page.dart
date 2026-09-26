import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'design/design.dart';
import 'own_route.dart';
import 'rust/api/profile.dart';

String contactId(String id) => id.length <= 12 ? id : id.substring(0, 12);

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.profile,
    this.selectRecipients = false,
  });
  final Profile profile;
  final bool selectRecipients;
  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  List<ContactView> _contacts = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _available(ContactView c) =>
      c.verified && c.devices.any((d) => !d.revoked);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final contacts = await widget.profile.contacts();
      contacts.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _selected.removeWhere(
          (id) => !contacts.any((c) => c.identityId == id && _available(c)),
        );
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.contactsReadFailed);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([ContactView? contact]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            ContactEditorPage(profile: widget.profile, contact: contact),
      ),
    );
    if (mounted) await _load();
  }

  List<SavedRecipientView> get _recipients => [
    for (final c in _contacts)
      if (_selected.contains(c.identityId) && _available(c))
        for (final device in c.devices)
          if (!device.revoked)
            SavedRecipientView(
              identityId: c.identityId,
              deviceId: device.deviceId,
            ),
  ];

  Widget _row(ContactView c) {
    final devices = c.devices.where((d) => !d.revoked).length;
    return ListTile(
      key: Key('contact-${c.identityId}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ArveilAvatar(identity: c.identityId, label: c.label, size: 40),
      title: NameLine(
        name: Text(c.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        verified: c.verified,
        unverified: !c.verified,
      ),
      subtitle: Text(
        c.devices.isEmpty
            ? context.l10n.contactNeedsRoute
            : context.l10n.contactDevicesAvailable(devices),
      ),
      trailing: widget.selectRecipients
          ? Checkbox(
              key: Key('select-contact-${c.identityId}'),
              value: _selected.contains(c.identityId),
              onChanged: _available(c) && !_loading
                  ? (value) => setState(() {
                      if (value == true) {
                        _selected.add(c.identityId);
                      } else {
                        _selected.remove(c.identityId);
                      }
                    })
                  : null,
            )
          : const Icon(Icons.chevron_right),
      onTap: _loading || widget.selectRecipients ? null : () => _edit(c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recipients = _recipients;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.selectRecipients
              ? context.l10n.contactsChoose
              : context.l10n.contactsTitle,
        ),
        actions: [
          IconButton(
            tooltip: context.l10n.contactAdd,
            onPressed: _loading ? null : () => _edit(),
            icon: const Icon(Icons.person_add_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: StatusBanner(
                  title: _error!,
                  icon: Icons.error_outline,
                  tone: BannerTone.error,
                  actions: [
                    TextButton(
                      onPressed: _load,
                      child: Text(context.l10n.retry),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: EdgeInsets.symmetric(
                      horizontal: WindowSize.of(context).margin,
                      vertical: 16,
                    ),
                    children: [
                      if (!widget.selectRecipients) ...[
                        SettingsGroup(
                          children: [
                            SettingsRow(
                              key: const Key('share-route'),
                              icon: Icons.share_outlined,
                              title: context.l10n.ownRouteTitle,
                              subtitle: context.l10n.shareMyRouteHelp,
                              onTap: () =>
                                  showOwnRoute(context, widget.profile),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        context.l10n.contactsNamesLocal,
                        style: ArveilType.secondary.copyWith(
                          color: ArveilColors.of(context).inkMuted,
                        ),
                      ),
                      if (widget.selectRecipients)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            context.l10n.contactsDeviceLimit,
                            style: ArveilType.secondary.copyWith(
                              color: ArveilColors.of(context).inkMuted,
                            ),
                          ),
                        ),
                      if (!_loading && _error == null && _contacts.isEmpty)
                        EmptyState(
                          icon: Icons.people_outline,
                          title: context.l10n.contactsEmpty,
                          action: FilledButton.icon(
                            onPressed: () => _edit(),
                            icon: const Icon(Icons.person_add_outlined),
                            label: Text(context.l10n.contactAdd),
                          ),
                        ),
                      if (_contacts.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        SettingsGroup(
                          children: [for (final c in _contacts) _row(c)],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (widget.selectRecipients)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    if (recipients.length > 16)
                      Text(context.l10n.contactsTooMany),
                    FilledButton(
                      key: const Key('use-contacts'),
                      onPressed:
                          _loading ||
                              _error != null ||
                              recipients.isEmpty ||
                              recipients.length > 16
                          ? null
                          : () => Navigator.pop(context, recipients),
                      child: Text(context.l10n.contactsUse(_selected.length)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ContactEditorPage extends StatefulWidget {
  const ContactEditorPage({super.key, required this.profile, this.contact});
  final Profile profile;
  final ContactView? contact;
  @override
  State<ContactEditorPage> createState() => _ContactEditorPageState();
}

class _ContactEditorPageState extends State<ContactEditorPage> {
  final _name = TextEditingController();
  final _route = TextEditingController();
  ContactView? _contact;
  RoutePreviewView? _preview;
  String? _checkedRoute;
  bool _compared = false;

  /// The user said the numbers differ: nothing may be verified.
  bool _mismatch = false;
  bool _busy = false;
  String? _error;
  String? _notice;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _contact = widget.contact;
    _name.text = _contact?.name ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _route.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    final route = _route.text.trim();
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
      _compared = false;
      _mismatch = false;
    });
    try {
      final preview = (await widget.profile.previewRoutes(
        routes: [route],
      )).single;
      if (!mounted || revision != _revision) return;
      setState(() {
        _preview = preview;
        _checkedRoute = route;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.contactRouteInvalid);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = _contact == null
          ? await widget.profile.saveContact(
              route: _checkedRoute!,
              name: _name.text,
              safetyNumber: _compared ? _preview!.safetyNumber : null,
            )
          : await widget.profile.renameContact(
              identityId: _contact!.identityId,
              name: _name.text,
            );
      if (!mounted) return;
      setState(() {
        _contact = result;
        _name.text = result.name ?? '';
        _route.clear();
        _checkedRoute = null;
        _preview = null;
        _compared = false;
        _mismatch = false;
        _notice = context.l10n.contactSaved;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.contactSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final contact = _contact!;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await widget.profile.verifyContact(
        identityId: contact.identityId,
        safetyNumber: contact.safetyNumber,
      );
      if (mounted) {
        setState(() {
          _contact = result;
          _compared = false;
          _notice = context.l10n.contactVerifiedNotice;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.contactVerifyFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Who is being added or looked at, and whether they were verified.
  Widget _identity(
    BuildContext context,
    String identity,
    ContactView? contact,
  ) {
    final c = ArveilColors.of(context);
    final name = _name.text.trim().isNotEmpty
        ? _name.text.trim()
        : contact?.label ?? contactId(identity);
    return Row(
      children: [
        ArveilAvatar(identity: identity, label: name, size: 52),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ArveilType.rowName.copyWith(color: c.ink),
              ),
              const SizedBox(height: 4),
              if (contact?.verified == true)
                Row(
                  children: [
                    const VerifiedMark(size: 15),
                    const SizedBox(width: 4),
                    Text(
                      context.l10n.verified,
                      style: ArveilType.secondary.copyWith(color: c.accent),
                    ),
                  ],
                )
              else
                const UnverifiedChip(),
              const SizedBox(height: 4),
              SelectableText(
                context.l10n.contactIdentity(contactId(identity)),
                style: ArveilType.identifier.copyWith(color: c.inkMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final contact = _contact;
    final number = contact?.safetyNumber ?? _preview?.safetyNumber;
    final identity = contact?.identityId ?? _preview?.identityId;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            contact == null
                ? context.l10n.contactAdd
                : context.l10n.contactDetails,
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('contact-name'),
                      controller: _name,
                      enabled: !_busy,
                      maxLength: 128,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      decoration: InputDecoration(
                        labelText: context.l10n.contactNameLabel,
                        helperText: context.l10n.contactNameHelper,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (contact == null) ...[
                      TextField(
                        key: const Key('contact-route'),
                        controller: _route,
                        enabled: !_busy,
                        minLines: 3,
                        maxLines: 6,
                        maxLength: 4096,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        decoration: InputDecoration(
                          labelText: context.l10n.contactRouteLabel,
                          helperText: context.l10n.contactRouteHelper,
                          counterText: '',
                        ),
                        onChanged: (_) => setState(() {
                          _revision++;
                          _preview = null;
                          _checkedRoute = null;
                          _compared = false;
                          _mismatch = false;
                          _error = null;
                        }),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _busy ? null : _prepare,
                        child: Text(context.l10n.contactPrepare),
                      ),
                    ],
                    if (identity != null) ...[
                      const SizedBox(height: 24),
                      _identity(context, identity, contact),
                      SectionTitle(context.l10n.safetyNumberTitle),
                      SafetyNumberGrid(
                        key: const Key('contact-safety'),
                        number: number!,
                        caption: context.l10n.contactCompareHelp,
                      ),
                      if (contact?.verified != true) ...[
                        const SizedBox(height: 12),
                        if (_mismatch)
                          StatusBanner(
                            key: const Key('contact-mismatch-warning'),
                            title: context.l10n.mismatchTitle,
                            body: context.l10n.mismatchBody,
                            icon: Icons.gpp_bad_outlined,
                            tone: BannerTone.error,
                          )
                        else if (_compared)
                          Text(context.l10n.comparedWillVerify),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                key: const Key('contact-mismatch'),
                                onPressed: _busy
                                    ? null
                                    : () => setState(() {
                                        _mismatch = true;
                                        _compared = false;
                                      }),
                                child: Text(context.l10n.numbersDiffer),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                key: const Key('contact-compared'),
                                onPressed: _busy || _compared
                                    ? null
                                    : () {
                                        if (contact != null) {
                                          _verify();
                                        } else {
                                          setState(() {
                                            _compared = true;
                                            _mismatch = false;
                                          });
                                        }
                                      },
                                child: Text(context.l10n.numbersMatch),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                    if (contact != null) ...[
                      SectionTitle(context.l10n.devicesTitle),
                      Text(context.l10n.contactRoutes(contact.devices.length)),
                      for (final device in contact.devices)
                        Text(
                          device.revoked
                              ? context.l10n.contactDeviceRevoked(
                                  contactId(device.deviceId),
                                )
                              : context.l10n.contactDevice(
                                  contactId(device.deviceId),
                                ),
                        ),
                      const SizedBox(height: 12),
                      Text(context.l10n.contactUpdateRoute),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('save-contact'),
                      onPressed: _busy || (contact == null && _preview == null)
                          ? null
                          : _save,
                      child: Text(
                        contact == null
                            ? context.l10n.contactSave
                            : context.l10n.contactSaveName,
                      ),
                    ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: LinearProgressIndicator(),
                      ),
                    if (_error ?? _notice case final message?)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: StatusBanner(
                          title: message,
                          icon: _error != null
                              ? Icons.error_outline
                              : Icons.check_circle_outline,
                          tone: _error != null
                              ? BannerTone.error
                              : BannerTone.info,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
