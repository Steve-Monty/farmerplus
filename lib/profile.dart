import 'package:flutter/material.dart';
import 'area_units.dart';
import 'location.dart';
import 'auth.dart';
import 'store.dart';
import 'ui.dart';

class ProfilePage extends StatefulWidget {
  final FarmStore store;
  const ProfilePage({super.key, required this.store});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  Map<String, dynamic> prior = {};
  String country = '', username = '', activity = 'None', unit = 'ha';
  String? id, status, error;
  bool loaded = false, locating = false, saving = false, dirty = false;
  bool derived = false;
  Future<void> draftWrites = Future.value();

  @override
  void initState() {
    super.initState();
    widget.store.addListener(changed);
    load();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> load() async {
    try {
      final rows = await widget.store.records('profile');
      final row = rows.firstOrNull;
      prior = Map<String, dynamic>.from(row?['data'] ?? {});
      id = row?['id'];
      final savedDraft = await widget.store.setting('profileDraft');
      final data = Map<String, dynamic>.from(savedDraft ?? prior);
      name.text = data['name'] ?? '';
      username = await widget.store.setting('accountName') ?? '';
      final gps = await widget.store.setting('gpsCountry');
      country = gps ?? data['country'] ?? '';
      derived = gps != null || data['countrySource'] == 'device-location';
      final selected = savedDraft != null
          ? data['primaryActivity']
          : await widget.store.setting('primaryActivity') ??
                data['primaryActivity'];
      activity = activities.contains(selected) ? selected : 'None';
      unit = AreaUnit.parse(
        savedDraft != null
            ? data['areaUnit'] ?? await widget.store.setting('areaUnit')
            : await widget.store.setting('areaUnit'),
      ).id;
      dirty = savedDraft != null;
      if (mounted) {
        setState(() {
          loaded = true;
          status = dirty ? 'Your unsaved draft has been restored.' : null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not load your profile. Try again.');
      }
    }
  }

  Map<String, dynamic> values() => {
    ...prior,
    'name': name.text.trim(),
    'country': country,
    'countrySource': derived ? 'device-location' : 'unverified',
    'primaryActivity': activity,
    'areaUnit': unit,
    'language': 'en',
    'verified': false,
  };

  void draft() {
    final data = values();
    setState(() {
      dirty = true;
      status = 'Saving draft…';
      error = null;
    });
    draftWrites = draftWrites
        .then((_) => widget.store.setSetting('profileDraft', data))
        .then((_) {
          if (mounted && !saving) {
            setState(
              () => status =
                  'Draft saved on this phone. Tap Save changes to apply.',
            );
          }
        })
        .catchError((Object _) {
          if (mounted) {
            setState(
              () => error =
                  'Could not save this draft. Keep this page open and try saving again.',
            );
          }
        });
  }

  Future<void> detectCountry() async {
    setState(() {
      locating = true;
      error = null;
    });
    try {
      if (!await DeviceLocation.enable(widget.store)) return;
      final found = await DeviceLocation.country(widget.store);
      if (!mounted) return;
      if (found == null) {
        setState(
          () => error =
              'Country is unavailable. You can still save your profile.',
        );
      } else {
        setState(() {
          country = found;
          derived = true;
        });
        draft();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Country is unavailable. You can still save your profile.',
        );
      }
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  Future<void> save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await draftWrites;
      final data = values();
      id = await widget.store.save(
        'profile',
        data,
        id: id ?? await widget.store.setting('farmerId'),
        settings: {
          'primaryActivity': activity,
          'areaUnit': unit,
          'profileDraft': null,
        },
      );
      prior = data;
      if (mounted) {
        setState(() {
          dirty = false;
          status = 'Saved on this phone';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not save your changes. Your draft is kept; please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(changed);
    name.dispose();
    super.dispose();
  }

  InputDecoration field(String label, {String? helper}) => InputDecoration(
    labelText: label,
    floatingLabelBehavior: FloatingLabelBehavior.always,
    helperText: helper,
    helperMaxLines: 3,
    errorMaxLines: 3,
    fillColor: Theme.of(context).colorScheme.surfaceContainerLowest,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
  );

  @override
  Widget build(BuildContext c) => PageFrame(
    'Your profile',
    bottom: loaded
        ? Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
            child: SafeArea(
              top: false,
              child: Align(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (status != null)
                          Semantics(
                            liveRegion: true,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                status!,
                                style: Theme.of(c).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        if (!dirty && id != null)
                          FutureBuilder<List<Map<String, Object?>>>(
                            future: widget.store.db.query(
                              'queue',
                              where: 'id=?',
                              whereArgs: [id],
                            ),
                            builder: (c, snapshot) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                !snapshot.hasData
                                    ? 'Checking sync status…'
                                    : snapshot.data!.isNotEmpty
                                    ? 'Profile waiting to sync'
                                    : 'Profile synced',
                                style: Theme.of(c).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        FilledButton(
                          onPressed: saving || !dirty ? null : save,
                          child: Text(saving ? 'Saving…' : 'Save changes'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          )
        : null,
    children: [
      const Text(
        'Add your details to personalise FarmerPlus. All fields are optional.',
      ),
      if (!loaded && error == null) const LinearProgressIndicator(),
      if (error != null) ...[
        Semantics(
          liveRegion: true,
          child: note(error!, icon: Icons.error_outline),
        ),
        if (!loaded) TextButton(onPressed: load, child: const Text('Retry')),
      ],
      if (loaded)
        Form(
          key: form,
          child: AbsorbPointer(
            absorbing: saving,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading(c, 'Personal details'),
                if (username.isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline),
                    title: Text(username),
                    subtitle: const Text('Your sign-in username'),
                  ),
                TextFormField(
                  controller: name,
                  onChanged: (_) => draft(),
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.nickname],
                  decoration: field('Preferred name'),
                ),
                gap(20),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.public),
                  title: Text(
                    country.isEmpty ? 'Country unavailable' : country,
                  ),
                  subtitle: Text(
                    derived
                        ? 'Country · From device location'
                        : 'Country · Not verified',
                  ),
                ),
                if (country.isEmpty || !derived)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: locating ? null : detectCountry,
                      icon: const Icon(Icons.my_location),
                      label: Text(
                        locating
                            ? 'Finding country…'
                            : 'Retry country from location',
                      ),
                    ),
                  ),
                gap(12),
                DropdownButtonFormField<String>(
                  initialValue: activity,
                  isExpanded: true,
                  decoration: field('Primary farming activity'),
                  items: activities
                      .map(
                        (a) => DropdownMenuItem(
                          value: a,
                          child: Text(a == 'None' ? 'Not specified' : a),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    activity = v!;
                    draft();
                  },
                ),
                heading(c, 'Preferences'),
                DropdownButtonFormField<String>(
                  initialValue: unit,
                  isExpanded: true,
                  decoration: field('Area units'),
                  items: AreaUnit.values
                      .map(
                        (u) =>
                            DropdownMenuItem(value: u.id, child: Text(u.label)),
                      )
                      .toList(),
                  onChanged: (v) {
                    unit = v!;
                    draft();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.language),
                  title: const Text('English'),
                  subtitle: const Text('App language'),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}
