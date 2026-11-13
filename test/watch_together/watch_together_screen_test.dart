import 'uburoom_test_requests.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:openwatchparty/openwatchparty.dart' as owp;
import 'package:plezy/focus/key_event_utils.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/models/watch_copy.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/watch_together/screens/watch_together_screen.dart';
import 'package:plezy/watch_together/services/recent_rooms_service.dart';
import 'package:plezy/watch_together/services/uburoom_auth_service.dart';
import 'package:plezy/watch_together/services/uburoom_socket_service.dart';
import 'package:plezy/watch_together/services/watch_party_relays.dart';
import 'package:plezy/watch_together/widgets/join_session_dialog.dart';
import 'package:plezy/watch_together/widgets/uburoom_lobby.dart';
import 'package:plezy/watch_together/widgets/uburoom_room_view.dart';
import 'package:plezy/watch_together/widgets/watch_room_sections.dart';
import 'package:provider/provider.dart';

import '../test_helpers/fake_owp_relay.dart';
import '../test_helpers/library_lookup.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/watch_room_harness.dart';

void _screenTest(String description, Future<void> Function(WidgetTester tester, WatchRoomHarness world) body) {
  testWidgets(description, (tester) async {
    final world = WatchRoomHarness(tester);
    try {
      await body(tester, world);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await world.close();
    }
  });
}

/// Pushes the Watch Together screen for [provider] over a home page, with a
/// tap.
Future<void> _openScreen(WidgetTester tester, WatchTogetherProvider provider) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(watchTestApp(provider, home: const WatchTestLauncher(screen: WatchTogetherScreen())));
  await tester.tap(find.text(WatchTestLauncher.label));
  await settleWatchFrames(tester);
}

/// Opens the screen as a keyboard or remote user does: an arrow starts the
/// focus session on the home page, Enter opens the screen.
Future<void> _openScreenWithKeys(WidgetTester tester, WatchTogetherProvider provider) async {
  await tester.pumpWidget(watchTestApp(provider, home: const WatchTestLauncher(screen: WatchTogetherScreen())));
  await pressWatchKey(tester, LogicalKeyboardKey.arrowDown);
  await pressWatchKey(tester, LogicalKeyboardKey.enter);
  expect(find.byType(WatchTogetherScreen), findsOneWidget);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await settleWatchFrames(tester);
}

bool _enabled(WidgetTester tester, String label) => tester
    .widget<ButtonStyleButton>(
      find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first,
    )
    .enabled;

bool _switchOn(WidgetTester tester, String title) =>
    tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title)).value;

Finder _row(String name) => find.widgetWithText(WatchParticipantTile, name);

owp.Participant _seenBy(WatchTogetherProvider viewer, WatchTogetherProvider who) =>
    viewer.participants.firstWhere((p) => p.peerId == who.myPeerId);

List<RecentRoom> _recentRooms(String profileId, [String? relay]) =>
    RecentRoomsService.getRecentRooms(profileId: profileId, relayScope: relayScopeOf(relay));

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    TvDetectionService.debugSetAppleTVOverride(false);
  });

  tearDown(() {
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    TvDetectionService.debugSetAppleTVOverride(null);
    BackKeyCoordinator.clear();
  });

  group('out of a room', () {
    _screenTest('configured uburoom server replaces relay instructions', (tester, world) async {
      await SettingsService.instance.write(SettingsService.uburoomServerUrl, 'https://watch.example');
      final provider = world.host();
      await _openScreen(tester, provider);
      expect(find.text('https://watch.example'), findsOneWidget);
      expect(find.text(t.watchTogether.relayPublic), findsNothing);
      final serverScope = provider.relayScope;
      await SettingsService.instance.write(SettingsService.uburoomServerUrl, null);
      expect(provider.uburoomServerUrl, isNull);
      provider.refreshServerSettings();
      await settleWatchFrames(tester);
      expect(find.text('https://watch.example'), findsNothing);
      expect(find.text('To create or join uburoom rooms, sign in to your server below.'), findsOneWidget);
      expect(provider.relayScope, isNot(serverScope));
    });
    _screenTest('Create Room makes the user host of a new room, shown by its K7M-Q2X code', (tester, world) async {
      final host = world.host(profileId: 'p1');
      await _openScreen(tester, host);
      expect(find.text(t.watchTogether.relayPublic), findsOneWidget);

      await tester.tap(find.text(t.watchTogether.createRoom));
      await world.until(() => host.isConnected, 'the room exists');
      await tester.pump();

      expect(world.relay.sent('create'), hasLength(1));
      expect(find.text('K7M-Q2X'), findsOneWidget);
      expect(find.text(t.watchTogether.youAreHost), findsOneWidget);
      final me = _row(t.watchTogether.nameYou(name: 'Anna'));
      expect(me, findsOneWidget);
      expect(find.descendant(of: me, matching: find.byType(WatchHostBadge)), findsOneWidget);
      expect(find.text(t.watchTogether.roomSettings), findsOneWidget);
      expect(find.text(t.watchTogether.nothingPlayingHost), findsOneWidget);
      expect(find.text(t.watchTogether.endRoom), findsOneWidget);
      await world.until(() => _recentRooms('p1').isNotEmpty, 'the room is remembered');
      expect(_recentRooms('p1').map((r) => r.code), [FakeOwpRelay.code]);
    });

    _screenTest('a create the relay refuses says why in the lobby, and Create Room works again', (tester, world) async {
      final other = world.host(name: 'Cleo');
      await world.settle(other.createRoom());
      final host = world.host();
      await _openScreen(tester, host);

      await tester.tap(find.text(t.watchTogether.createRoom));
      await world.until(
        () => find.text(t.watchTogether.errors.rateLimited).evaluate().isNotEmpty,
        'the lobby says why',
      );
      expect(host.isInSession, isFalse);
      expect(_enabled(tester, t.watchTogether.createRoom), isTrue);
      expect(_enabled(tester, t.watchTogether.joinRoom), isTrue);

      other.leave();
      await world.until(() => world.relay.peerIds.isEmpty, 'the other room is gone');
      await tester.tap(find.text(t.watchTogether.createRoom));
      await world.until(() => host.isConnected, 'the room exists');
      await tester.pump();
      expect(find.text(t.watchTogether.errors.rateLimited), findsNothing);
      expect(find.text('K7M-Q2X'), findsOneWidget);
    });

    _screenTest('Join Room asks for the code and shows the room once joined', (tester, world) async {
      final host = world.host();
      await world.settle(host.createRoom());
      final guest = world.guest();
      await _openScreen(tester, guest);

      await tester.tap(find.text(t.watchTogether.joinRoom));
      await settleWatchFrames(tester);
      expect(find.byType(JoinRoomDialog), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'k7mq2x');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await world.until(() => guest.isConnected, 'the guest is in');
      await settleWatchFrames(tester);

      expect(find.byType(JoinRoomDialog), findsNothing);
      expect(find.text('K7M-Q2X'), findsOneWidget);
      expect(find.text(t.watchTogether.hostedBy(name: 'Anna')), findsOneWidget);
    });

    _screenTest('recent rooms of this relay are listed; a tile joins its room, makes it again, or says why it cannot', (
      tester,
      world,
    ) async {
      await RecentRoomsService.addOrUpdateRoom('ABC234', profileId: 'p1', relayScope: relayScopeOf(null));
      await RecentRoomsService.renameRoom('ABC234', 'Movie night', profileId: 'p1', relayScope: relayScopeOf(null));
      await RecentRoomsService.addOrUpdateRoom(FakeOwpRelay.code, profileId: 'p1', relayScope: relayScopeOf(null));
      await RecentRoomsService.addOrUpdateRoom('XYZ789', profileId: 'p1', relayScope: relayScopeOf('https://r.test'));
      final host = world.host();
      await world.settle(host.createRoom());
      final guest = world.guest(profileId: 'p1');
      await _openScreen(tester, guest);

      expect(find.text(t.watchTogether.recentRooms), findsOneWidget);
      expect(find.text('K7M-Q2X'), findsOneWidget);
      expect(find.text('Movie night'), findsOneWidget);
      expect(find.text('ABC-234'), findsOneWidget, reason: 'a named room shows its code under the name');
      expect(find.text('XYZ-789'), findsNothing, reason: 'that room is on another relay');

      await _tap(tester, find.text('K7M-Q2X'));
      await world.until(() => guest.isConnected, 'the guest is in');
      await tester.pump();
      expect(find.text(t.watchTogether.hostedBy(name: 'Anna')), findsOneWidget);
      expect(guest.isHost, isFalse, reason: 'the room exists, so the tile joins it');

      host.endRoom();
      await world.until(() => !guest.isInSession, 'the room is over');
      await settleWatchFrames(tester);
      await _tap(tester, find.text('Movie night'));
      await world.until(() => guest.isConnected, 'the room is made again');
      await tester.pump();
      expect((guest.roomCode, guest.isHost), ('ABC234', true));
      expect(world.relay.sent('join').last['create'], isTrue);

      guest.leave();
      await world.until(() => !guest.isInSession, 'the guest left');
      await settleWatchFrames(tester);
      world.relay.refuseJoins = owp.ErrorCode.relayFull;
      await _tap(tester, find.text('K7M-Q2X'));
      await world.until(() => find.text(t.watchTogether.errors.relayFull).evaluate().isNotEmpty, 'the lobby says why');
      expect(guest.isInSession, isFalse);
    });

    _screenTest('a recent room is renamed, unnamed and removed from its actions', (tester, world) async {
      await RecentRoomsService.addOrUpdateRoom(FakeOwpRelay.code, profileId: 'p1', relayScope: relayScopeOf(null));
      final guest = world.guest(profileId: 'p1');
      await _openScreen(tester, guest);

      Future<void> rename(String name) async {
        await _tap(tester, find.byTooltip(t.watchTogether.roomActions));
        await tester.tap(find.text(t.watchTogether.renameRoom));
        await settleWatchFrames(tester);
        await tester.enterText(find.byType(TextField), name);
        await tester.tap(find.text(t.common.save));
        await settleWatchFrames(tester);
      }

      await rename('  Friday  ');
      expect(find.text('Friday'), findsOneWidget);
      expect(find.text('K7M-Q2X'), findsOneWidget, reason: 'the code under the name');
      expect(_recentRooms('p1').single.name, 'Friday');

      await rename(' ');
      expect(find.text('Friday'), findsNothing);
      expect(find.text('K7M-Q2X'), findsOneWidget);
      expect(_recentRooms('p1').single.name, isNull);

      await _tap(tester, find.byTooltip(t.watchTogether.roomActions));
      await tester.tap(find.text(t.watchTogether.removeRoom));
      await settleWatchFrames(tester);
      expect(find.text('K7M-Q2X'), findsNothing);
      expect(find.text(t.watchTogether.recentRooms), findsNothing);
      expect(_recentRooms('p1'), isEmpty);
    });

    _screenTest('the lobby names the relay rooms use, and lists only that relay rooms', (tester, world) async {
      await RecentRoomsService.addOrUpdateRoom(FakeOwpRelay.code, profileId: 'p1', relayScope: relayScopeOf(null));
      await _openScreen(tester, world.guest(profileId: 'p1'));
      expect(find.text(t.watchTogether.relayPublic), findsOneWidget);
      expect(find.text('K7M-Q2X'), findsOneWidget);

      await _openScreen(tester, world.member('Ben', profileId: 'p1', relayBaseUrl: 'https://relay.example.com'));
      expect(find.text(t.watchTogether.relayCustom(url: 'https://relay.example.com')), findsOneWidget);
      expect(find.text(t.watchTogether.relayPublic), findsNothing);
      expect(find.text('K7M-Q2X'), findsNothing, reason: 'that code belongs to the public relays');
    });
  });

  group('in a room', () {
    _screenTest('Copy Code and Share Invite put the formatted code on the clipboard', (tester, world) async {
      final copied = mockWatchClipboard();
      final host = world.host();
      await world.settle(host.createRoom());
      await _openScreen(tester, host);

      await _tap(tester, find.text(t.watchTogether.copyCode));
      expect(copied, ['K7M-Q2X']);
      expect(find.text(t.watchTogether.codeCopied), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));
      await settleWatchFrames(tester);
      await _tap(tester, find.text(t.watchTogether.shareInvite));
      expect(copied.last, t.watchTogether.inviteMessage(code: 'K7M-Q2X'));
      expect(find.text(t.watchTogether.inviteCopied), findsOneWidget);
    });

    _screenTest('participants: who hosts, who is you, and each one app, connection, player and match', (
      tester,
      world,
    ) async {
      final alien = watchMovie(id: 'alien');
      final host = world.host();
      final guest = world.guest(
        copies: () => [watchMovie(id: 'g-alien', serverId: watchGuestServerId, durationMs: 7020800, version: 'g-hd')],
      );
      final screen = WatchTestScreen(guest);
      await world.together(host, [guest]);
      await _openScreen(tester, host);

      final anna = _row(t.watchTogether.nameYou(name: 'Anna'));
      expect(find.descendant(of: anna, matching: find.byType(WatchHostBadge)), findsOneWidget);
      expect(find.descendant(of: _row('Ben'), matching: find.byType(WatchHostBadge)), findsNothing);
      expect(find.descendant(of: _row('Ben'), matching: find.text('Plezy · Connected · Idle')), findsOneWidget);

      await world.hostPlays(host, alien);
      await world.until(() => guest.isFollowing, 'the guest follows');
      await world.until(() => _seenBy(host, guest).match?.state == owp.MatchState.matched, 'the host sees the match');
      await tester.pump();
      expect(find.descendant(of: _row('Ben'), matching: find.textContaining(t.watchTogether.matchMatched)), findsOne);

      final guestPlayer = screen.players.single;
      guestPlayer.player.emitBuffering(true);
      guest.playerChanged(guestPlayer.adapter);
      await world.until(() => _seenBy(host, guest).player == owp.PlayerState.buffering, 'the host sees the buffering');
      await tester.pump();
      expect(
        find.descendant(of: _row('Ben'), matching: find.textContaining(t.watchTogether.playerBuffering)),
        findsOneWidget,
      );
    });

    _screenTest('host settings: who controls playback and the lock reach the room', (tester, world) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, host);
      expect(_switchOn(tester, t.watchTogether.letEveryoneControl), isFalse);
      expect(find.text(t.watchTogether.hostControlsPlayback), findsNWidgets(2));

      await _tap(tester, find.text(t.watchTogether.letEveryoneControl));
      await world.until(() => guest.canControl, 'the guest controls playback');
      await tester.pump();
      expect(_switchOn(tester, t.watchTogether.letEveryoneControl), isTrue);
      expect(find.text(t.watchTogether.anyoneCanControl), findsNWidgets(2));

      await _tap(tester, find.text(t.watchTogether.lockRoom));
      await world.until(() => guest.isLocked, 'the guest sees the lock');
      await tester.pump();
      expect(_switchOn(tester, t.watchTogether.lockRoom), isTrue);
      expect(find.text(t.watchTogether.roomLocked), findsOneWidget);

      await _tap(tester, find.text(t.watchTogether.lockRoom));
      await world.until(() => !guest.isLocked, 'the guest sees the unlock');
      await tester.pump();
      expect(find.text(t.watchTogether.roomLocked), findsNothing);
    });

    _screenTest('Make host asks first, then hands the room over', (tester, world) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, host);

      await _tap(tester, _row('Ben'));
      expect(find.text(t.watchTogether.removeParticipant), findsOneWidget);
      await tester.tap(find.text(t.watchTogether.makeHost));
      await settleWatchFrames(tester);
      expect(find.text(t.watchTogether.makeHostQuestion), findsOneWidget);
      expect(find.text(t.watchTogether.makeHostConfirm(name: 'Ben')), findsOneWidget);

      await tester.tap(find.text(t.common.cancel));
      await settleWatchFrames(tester);
      expect(world.relay.sent('transferHost'), isEmpty);
      expect(find.text(t.watchTogether.makeHost), findsOneWidget, reason: 'the actions stay open');

      await tester.tap(find.text(t.watchTogether.makeHost));
      await settleWatchFrames(tester);
      await tester.tap(find.text(t.watchTogether.transfer));
      await world.until(() => guest.isHost && !host.isHost, 'Ben hosts');
      await settleWatchFrames(tester);

      expect(find.text(t.watchTogether.makeHost), findsNothing, reason: 'the actions closed');
      expect(find.text(t.watchTogether.hostedBy(name: 'Ben')), findsOneWidget);
      expect(find.descendant(of: _row('Ben'), matching: find.byType(WatchHostBadge)), findsOneWidget);
      expect(find.text(t.watchTogether.roomSettings), findsNothing);
      expect(find.text(t.watchTogether.endRoom), findsNothing);
      expect(tester.takeException(), isNull);
    });

    _screenTest('Remove asks first; the row goes once the relay drops the guest', (tester, world) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, host);

      await _tap(tester, _row('Ben'));
      await tester.tap(find.text(t.watchTogether.removeParticipant));
      await settleWatchFrames(tester);
      expect(find.text(t.watchTogether.removeParticipantQuestion(name: 'Ben')), findsOneWidget);
      await tester.tap(find.text(t.common.cancel));
      await settleWatchFrames(tester);
      expect(world.relay.sent('kick'), isEmpty);
      expect(_row('Ben'), findsOneWidget);

      await tester.tap(find.text(t.watchTogether.removeParticipant));
      await settleWatchFrames(tester);
      await tester.tap(find.text(t.watchTogether.remove));
      await world.until(() => host.participantCount == 1, 'the relay dropped the guest');
      await settleWatchFrames(tester);

      expect(_row('Ben'), findsNothing);
      expect(find.text(t.watchTogether.removeParticipant), findsNothing, reason: 'the actions closed');
      expect(guest.state.endReason, owp.EndReason.kicked);
      expect(host.isConnected, isTrue);
      expect(tester.takeException(), isNull);
    });

    _screenTest('Leave asks first; leaving shows the lobby and the others see the user go', (tester, world) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, guest);

      await _tap(tester, find.text(t.watchTogether.leaveRoom));
      expect(find.text(t.watchTogether.leaveRoomQuestion), findsOneWidget);
      await tester.tap(find.text(t.common.cancel));
      await settleWatchFrames(tester);
      expect(guest.isConnected, isTrue);
      expect(find.text('K7M-Q2X'), findsOneWidget);

      await _tap(tester, find.text(t.watchTogether.leaveRoom));
      await tester.tap(find.text(t.watchTogether.leave));
      await world.until(() => !guest.isInSession, 'the guest is out');
      await world.until(() => host.participantCount == 1, 'the host sees the guest go');
      await settleWatchFrames(tester);
      expect(guest.state.endReason, owp.EndReason.left);
      expect(find.text(t.watchTogether.createRoom), findsOneWidget);
      expect(find.text('K7M-Q2X'), findsNothing);
    });

    _screenTest('End asks first and ends the room for everyone', (tester, world) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, host);

      await _tap(tester, find.text(t.watchTogether.endRoom));
      expect(find.text(t.watchTogether.endRoomQuestion), findsOneWidget);
      await tester.tap(find.text(t.common.cancel));
      await settleWatchFrames(tester);
      expect(world.relay.sent('end'), isEmpty);

      await _tap(tester, find.text(t.watchTogether.endRoom));
      await tester.tap(find.text(t.watchTogether.end));
      await world.until(() => !host.isInSession && !guest.isInSession, 'the room is over');
      await settleWatchFrames(tester);
      expect(guest.state.endReason, owp.EndReason.ended);
      expect(find.text(t.watchTogether.createRoom), findsOneWidget);
    });

    _screenTest('the side safe area insets the screen once; its list tiles add none of it again', (
      tester,
      world,
    ) async {
      // An iPhone in landscape: 62 logical pixels on each side.
      final ratio = tester.view.devicePixelRatio;
      tester.view.padding = FakeViewPadding(left: 62 * ratio, right: 62 * ratio);
      addTearDown(tester.view.resetPadding);
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, guest);

      final tile = find.descendant(of: _row('Anna'), matching: find.byType(ListTile)).first;
      final padding = MediaQuery.paddingOf(tester.element(tile));
      expect((padding.left, padding.right), (0.0, 0.0));
      expect(tester.getTopLeft(tile).dx, greaterThanOrEqualTo(62));
      expect(tester.getTopRight(tile).dx, lessThanOrEqualTo(tester.view.physicalSize.width / ratio - 62));
    });

    _screenTest('a guest sees who hosts, but no host settings, End Room or participant actions', (tester, world) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, guest);

      expect(find.text(t.watchTogether.hostedBy(name: 'Anna')), findsOneWidget);
      expect(find.text(t.watchTogether.nothingPlayingGuest), findsOneWidget);
      expect(find.descendant(of: _row('Anna'), matching: find.byType(WatchHostBadge)), findsOneWidget);
      expect(find.text(t.watchTogether.roomSettings), findsNothing);
      expect(find.text(t.watchTogether.endRoom), findsNothing);
      expect(find.text(t.watchTogether.leaveRoom), findsOneWidget);

      await _tap(tester, _row('Anna'));
      expect(find.text(t.watchTogether.makeHost), findsNothing);
      expect(find.text(t.watchTogether.removeParticipant), findsNothing);
    });

    _screenTest('the reconnecting banner shows while the connection is down', (tester, world) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, guest);
      expect(find.text(t.watchTogether.reconnecting), findsNothing);

      world.relay.drop(guest.myPeerId!);
      await world.until(() => guest.isReconnecting, 'the guest reconnects');
      await tester.pump();

      expect(find.text(t.watchTogether.reconnecting), findsOneWidget);
      expect(find.text(t.watchTogether.reconnectingDescription), findsOneWidget);
      expect(find.text('K7M-Q2X'), findsOneWidget, reason: 'the room stays on screen');
      await world.until(() => !_seenBy(host, guest).connected, 'the host sees the drop');
    });

    _screenTest('a host sees a dropped guest as disconnected', (tester, world) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, host);

      world.relay.drop(guest.myPeerId!);
      await world.until(() => !_seenBy(host, guest).connected, 'the host sees the drop');
      await tester.pump();
      expect(find.descendant(of: _row('Ben'), matching: find.text('Plezy · Disconnected')), findsOneWidget);
    });

    _screenTest('a video without catalogue identity is marked as not shareable; a movie is not', (tester, world) async {
      final host = world.host();
      await world.settle(host.createRoom());
      await _openScreen(tester, host);

      await world.hostPlays(host, watchMovie(id: 'alien'));
      await tester.pump();
      expect(find.text('Alien (1979)'), findsWidgets);
      expect(find.text(t.watchTogether.sharingYourCopy), findsOneWidget);
      expect(find.text(t.watchTogether.notShareable), findsNothing);

      await world.hostPlays(host, watchMovie(id: 'home', title: 'Birthday', kind: MediaKind.clip));
      await tester.pump();
      expect(host.media?.kind, owp.MediaKind.video);
      expect(find.text('Birthday'), findsWidgets);
      expect(find.text(t.watchTogether.notShareable), findsOneWidget);
    });

    _screenTest('Join Current Playback opens the room file for a guest who is not watching it', (tester, world) async {
      final guestAlien = watchMovie(id: 'g-alien', serverId: watchGuestServerId, version: 'g-hd');
      final host = world.host();
      final guest = world.guest(copies: () => [guestAlien]);
      final screen = WatchTestScreen(guest);
      final opened = <WatchCopy>[];
      // The room's own open fails (the player could not start); the card
      // then opens it on request.
      guest.navigatorOpener = (copy) async {
        opened.add(copy);
        return opened.length > 1 && await screen.open(copy);
      };
      await world.together(host, [guest]);
      await _openScreen(tester, guest);

      await world.hostPlays(host, watchMovie(id: 'alien'));
      await world.until(() => guest.canJoinPlayback, 'the guest may join');
      await tester.pump();
      expect(opened, [watchCopyOf(guestAlien)]);
      expect(find.text(t.watchTogether.joinCurrentPlayback), findsOneWidget);

      await _tap(tester, find.text(t.watchTogether.joinCurrentPlayback));
      await world.until(() => guest.isFollowing, 'the guest follows');
      await tester.pump();
      expect(opened, [watchCopyOf(guestAlien), watchCopyOf(guestAlien)]);
      expect(find.text(t.watchTogether.joinCurrentPlayback), findsNothing);
    });

    _screenTest('a search that failed on a server says so, on the room and on the copies page, until searched again', (
      tester,
      world,
    ) async {
      final guestAlien = watchMovie(id: 'g-alien', serverId: watchGuestServerId, version: 'g-hd');
      var failing = true;
      final host = world.host();
      final guest = world.member(
        'Ben',
        findCopies: (query, {abort}) async => failing
            ? libraryLookupResult(const [], failed: {watchGuestServerId})
            : libraryLookupResult([guestAlien], succeeded: {watchGuestServerId}),
      );
      guest.navigatorOpener = (_) async => false;
      await world.together(host, [guest]);
      await _openScreen(tester, guest);

      await world.hostPlays(host, watchMovie(id: 'alien'));
      await world.until(() => guest.searchFailed, 'the search failed');
      await tester.pump();
      expect(find.text(t.watchTogether.notices.searchFailed), findsOneWidget);
      expect(find.text(t.watchTogether.unavailableTitle), findsNothing, reason: 'not found is not the same as absent');

      await _tap(tester, find.text(t.watchTogether.chooseCopy));
      expect(find.byType(WatchCandidatesPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(WatchCandidatesPage),
          matching: find.text(t.watchTogether.notices.searchFailed),
        ),
        findsOneWidget,
      );
      expect(find.text(t.watchTogether.noCandidates), findsNothing);

      failing = false;
      await _tap(tester, find.text(t.watchTogether.searchAgain).last);
      await world.until(() => guest.state.candidates.isNotEmpty, 'the copy is found');
      await tester.pump();
      expect(guest.searchFailed, isFalse);
      expect(find.text(t.watchTogether.notices.searchFailed), findsNothing);
    });
  });

  group('keyboard and D-pad', () {
    _screenTest('the lobby focuses Create Room, arrows move between its buttons, Back leaves the screen', (
      tester,
      world,
    ) async {
      await _openScreenWithKeys(tester, world.guest());
      expectWatchFocus(t.watchTogether.createRoom);

      await pressWatchKey(tester, LogicalKeyboardKey.arrowDown);
      expectWatchFocus(t.watchTogether.joinRoom);
      await pressWatchKey(tester, LogicalKeyboardKey.arrowUp);
      expectWatchFocus(t.watchTogether.createRoom);

      await pressWatchKey(tester, LogicalKeyboardKey.escape);
      expect(find.byType(WatchTogetherScreen), findsNothing);
      expect(find.text(WatchTestLauncher.label), findsOneWidget);
    });

    _screenTest('a room created with the keyboard focuses Copy Code; arrows reach every room control', (
      tester,
      world,
    ) async {
      final host = world.host();
      final guest = world.guest();
      await _openScreenWithKeys(tester, host);
      await pressWatchKey(tester, LogicalKeyboardKey.enter);
      await world.until(() => host.isConnected, 'the room exists');
      await world.together(host, [guest]);
      await settleWatchFrames(tester);
      expectWatchFocus(t.watchTogether.copyCode);

      Future<void> press(LogicalKeyboardKey key, String expected) async {
        await pressWatchKey(tester, key);
        expectWatchFocus(expected);
      }

      await press(LogicalKeyboardKey.arrowRight, t.watchTogether.shareInvite);
      await press(LogicalKeyboardKey.arrowLeft, t.watchTogether.copyCode);
      await press(LogicalKeyboardKey.arrowDown, 'Ben');
      await press(LogicalKeyboardKey.arrowDown, t.watchTogether.letEveryoneControl);
      await press(LogicalKeyboardKey.arrowDown, t.watchTogether.lockRoom);
      await press(LogicalKeyboardKey.arrowDown, t.watchTogether.leaveRoom);
      await press(LogicalKeyboardKey.arrowRight, t.watchTogether.endRoom);
      await press(LogicalKeyboardKey.arrowLeft, t.watchTogether.leaveRoom);
      await press(LogicalKeyboardKey.arrowUp, t.watchTogether.lockRoom);

      // Select toggles a setting.
      await press(LogicalKeyboardKey.enter, t.watchTogether.lockRoom);
      await world.until(() => guest.isLocked, 'the room is locked');
    });

    _screenTest('Back closes a confirmation, then the participant actions, and only then the screen', (
      tester,
      world,
    ) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreenWithKeys(tester, host);
      expectWatchFocus(t.watchTogether.copyCode);

      await pressWatchKey(tester, LogicalKeyboardKey.arrowDown);
      expectWatchFocus('Ben');
      await pressWatchKey(tester, LogicalKeyboardKey.enter);
      expectWatchFocus(t.watchTogether.makeHost);
      await pressWatchKey(tester, LogicalKeyboardKey.arrowDown);
      expectWatchFocus(t.watchTogether.removeParticipant);
      await pressWatchKey(tester, LogicalKeyboardKey.enter);
      expect(find.text(t.watchTogether.removeParticipantQuestion(name: 'Ben')), findsOneWidget);
      expectWatchFocus(t.common.cancel);

      // A remote's Back.
      await pressWatchKey(tester, LogicalKeyboardKey.gameButtonB);
      expect(find.text(t.watchTogether.removeParticipantQuestion(name: 'Ben')), findsNothing);
      expect(find.text(t.watchTogether.removeParticipant), findsOneWidget, reason: 'the actions stay open');
      expectWatchFocus(t.watchTogether.removeParticipant);

      await pressWatchKey(tester, LogicalKeyboardKey.gameButtonB);
      expect(find.text(t.watchTogether.removeParticipant), findsNothing);
      expect(find.byType(WatchTogetherScreen), findsOneWidget);
      expectWatchFocus('Ben');

      await pressWatchKey(tester, LogicalKeyboardKey.gameButtonB);
      expect(find.byType(WatchTogetherScreen), findsNothing);
      expect(world.relay.sent('kick'), isEmpty);
      expect(host.isConnected, isTrue, reason: 'leaving the screen keeps the room');
    });

    _screenTest('system Back closes a dialog, then a sheet, and only then the screen', (tester, world) async {
      final host = world.host();
      final guest = world.guest();
      await world.together(host, [guest]);
      await _openScreen(tester, host);

      await _tap(tester, find.text(t.watchTogether.leaveRoom));
      expect(find.text(t.watchTogether.leaveRoomQuestion), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settleWatchFrames(tester);
      expect(find.text(t.watchTogether.leaveRoomQuestion), findsNothing);
      expect(find.byType(WatchTogetherScreen), findsOneWidget);

      await _tap(tester, _row('Ben'));
      expect(find.text(t.watchTogether.makeHost), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settleWatchFrames(tester);
      expect(find.text(t.watchTogether.makeHost), findsNothing);
      expect(find.byType(WatchTogetherScreen), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settleWatchFrames(tester);
      expect(find.byType(WatchTogetherScreen), findsNothing);
      expect(host.isConnected, isTrue);
      expect(world.relay.sent('leave'), isEmpty);
    });
  });

  group('uburoom session and lobby', () {
    testWidgets('UburoomRoomView displays room header with copy button and saved room badge', (tester) async {
      final socket = _TestUburoomSocketService();
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth, viewerId: 'viewer-alice');
      addTearDown(provider.dispose);

      provider.setUburoomSessionForTest(
        roomId: 'uburoom-room-xyz',
        serverUrl: 'https://watch.example',
        token: 'mock-token',
      );
      provider.handleUburoomSnapshotForTest({
        'id': 'uburoom-room-xyz',
        'name': 'Movie Lounge',
        'epoch': 'epoch-1',
        'revision': 1,
        'durable': true,
        'isHost': true,
        'canPlayback': true,
        'canManage': true,
        'participants': [
          {'id': 'viewer-alice', 'name': 'Alice', 'role': 'host', 'isHost': true, 'present': true},
        ],
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: UburoomRoomView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Movie Lounge'), findsOneWidget);
      expect(find.text('uburoom-room-xyz'), findsOneWidget);
      expect(find.text('Saved room'), findsOneWidget);

      final copyButton = find.byTooltip('Copy room ID');
      expect(copyButton, findsOneWidget);
      expect(find.descendant(of: copyButton, matching: find.byIcon(Symbols.content_copy_rounded)), findsOneWidget);

      final copied = mockWatchClipboard();
      await tester.tap(copyButton);
      await tester.pump();
      expect(copied, contains('uburoom-room-xyz'));
      expect(find.text(t.watchTogether.codeCopied), findsOneWidget);
    });

    testWidgets('UburoomRoomView displays playback controls including Stop button for host', (tester) async {
      final socket = _TestUburoomSocketService();
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth, viewerId: 'viewer-alice');
      addTearDown(provider.dispose);

      provider.setUburoomSessionForTest(
        roomId: 'uburoom-room-xyz',
        serverUrl: 'https://watch.example',
        token: 'mock-token',
      );
      provider.handleUburoomSnapshotForTest({
        'id': 'uburoom-room-xyz',
        'name': 'Durable Stream',
        'epoch': 'epoch-1',
        'revision': 1,
        'durable': true,
        'mediaId': 'plex-123',
        'title': 'Interstellar',
        'subtitle': 'Sci-Fi · 2014',
        'duration': 10140.0,
        'position': 120.0,
        'state': {'paused': false},
        'isHost': true,
        'canPlayback': true,
        'canManage': true,
        'participants': [
          {
            'id': 'viewer-alice',
            'name': 'Alice',
            'role': 'host',
            'isHost': true,
            'present': true,
            'syncQuality': {'status': 'playing', 'level': 'good'},
          },
          {'id': 'viewer-bob', 'name': 'Bob', 'role': 'viewer', 'isHost': false, 'present': false},
        ],
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: UburoomRoomView())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Interstellar'), findsOneWidget);
      expect(find.text('Sci-Fi · 2014'), findsOneWidget);

      // Play/Pause button: since paused is false, shows Pause
      final pauseButton = find.widgetWithText(OutlinedButton, 'Pause');
      expect(pauseButton, findsOneWidget);
      await tester.tap(pauseButton);
      await tester.pump();
      expect(socket.requests.any((r) => r.$1 == 'command' && r.$2?['command']?['action'] == 'media.pause'), isTrue);

      // Stop button for host
      final stopButton = find.widgetWithText(OutlinedButton, 'Stop');
      expect(stopButton, findsOneWidget);
      expect(find.descendant(of: stopButton, matching: find.byIcon(Symbols.stop_rounded)), findsOneWidget);

      await tester.tap(stopButton);
      await tester.pump();
      // Durable room sends queue.clear
      expect(socket.requests.any((r) => r.$1 == 'command' && r.$2?['command']?['action'] == 'queue.clear'), isTrue);

      // Participant list verification
      expect(find.text('Participants (2)'), findsOneWidget);
      expect(find.text('Alice (You)'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      expect(find.textContaining('Connected'), findsWidgets);
      expect(find.textContaining('Sync: good'), findsWidgets);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.textContaining('Offline'), findsWidgets);
    });

    testWidgets('UburoomRoomView guest does not see Stop or End room buttons, and non-durable room lacks badge', (
      tester,
    ) async {
      final socket = _TestUburoomSocketService();
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth, viewerId: 'viewer-bob');
      addTearDown(provider.dispose);

      provider.setUburoomSessionForTest(
        roomId: 'uburoom-room-guest',
        serverUrl: 'https://watch.example',
        token: 'mock-token',
      );
      provider.handleUburoomSnapshotForTest({
        'id': 'uburoom-room-guest',
        'name': 'Public Room',
        'epoch': 'epoch-2',
        'revision': 1,
        'durable': false,
        'mediaId': 'plex-456',
        'title': 'Inception',
        'state': {'paused': true},
        'isHost': false,
        'canPlayback': true,
        'canManage': false,
        'participants': [
          {'id': 'viewer-charlie', 'name': 'Charlie', 'role': 'host', 'isHost': true, 'present': true},
          {'id': 'viewer-bob', 'name': 'Bob', 'role': 'viewer', 'isHost': false, 'present': true},
        ],
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: UburoomRoomView())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Non-durable room does not show Saved room badge
      expect(find.text('Saved room'), findsNothing);

      // Play button is shown because paused is true
      final playButton = find.widgetWithText(OutlinedButton, 'Play');
      expect(playButton, findsOneWidget);
      await tester.tap(playButton);
      await tester.pump();
      expect(socket.requests.any((r) => r.$1 == 'command' && r.$2?['command']?['action'] == 'media.play'), isTrue);

      // Stop button is NOT shown for guest
      expect(find.widgetWithText(OutlinedButton, 'Stop'), findsNothing);

      // End room button is NOT shown for guest, but Leave room is shown
      expect(find.text(t.watchTogether.endRoom), findsNothing);
      expect(find.text(t.watchTogether.leaveRoom), findsOneWidget);
    });

    testWidgets('UburoomLobby displays rich room cards with active status, viewer count, playing title and room ID', (
      tester,
    ) async {
      final socket = _TestUburoomSocketService();
      socket.roomsToReturn = [
        {'id': 'room-alpha-123', 'name': 'Movie Night', 'active': true, 'viewers': 4, 'title': 'Blade Runner 2049'},
        {'id': 'room-gamma-789', 'name': 'Gaming Lounge', 'active': true, 'viewers': 1},
        {'id': 'room-delta-000', 'name': 'Casual Hangout', 'active': true},
      ];
      socket.savedRoomsToReturn = [
        {'id': 'room-beta-456', 'name': 'Anime Club', 'active': false},
      ];
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth);
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: UburoomLobby())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify rich subtitles
      expect(find.text('Active room · 4 watching · Blade Runner 2049 · room-alpha-123'), findsOneWidget);
      expect(find.text('Saved room · room-beta-456'), findsOneWidget);
      expect(find.text('Active room · 1 watching · room-gamma-789'), findsOneWidget);
      expect(find.text('Active room · room-delta-000'), findsOneWidget);

      // Verify button labels
      expect(find.text('Create Room'), findsOneWidget);
      expect(find.text('Join by name or link'), findsOneWidget);
      expect(find.text('Uburoom Server Settings'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);

      // Trailing buttons: Reopen for saved room, Join for active rooms
      expect(find.text('Reopen'), findsOneWidget);
      expect(find.text('Join'), findsNWidgets(3));

      // Tapping a saved room triggers reopen then join
      await tester.tap(find.text('Anime Club'));
      await tester.pumpAndSettle();
      expect(socket.requests.any((r) => r.$1 == 'room.reopen'), isTrue);
    });

    testWidgets('UburoomRoomView displays Queue card with items, Auto-queue badge, and Private visibility badge', (
      tester,
    ) async {
      final socket = _TestUburoomSocketService();
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth, viewerId: 'viewer-alice');
      addTearDown(provider.dispose);

      provider.setUburoomSessionForTest(
        roomId: 'uburoom-room-private',
        serverUrl: 'https://watch.example',
        token: 'mock-token',
      );
      provider.handleUburoomSnapshotForTest({
        'id': 'uburoom-room-private',
        'name': 'Secret Cinema',
        'epoch': 'epoch-1',
        'revision': 1,
        'durable': true,
        'visibility': 'private',
        'autoQueue': true,
        'mediaId': 'plex-1',
        'title': 'Batman Begins',
        'queue': [
          {
            'id': 'q-1',
            'mediaId': 'plex-2',
            'title': 'The Dark Knight',
            'subtitle': 'Action · 2008',
            'durationSeconds': 9120.0,
          },
          {'id': 'q-2', 'mediaId': 'plex-3', 'title': 'The Dark Knight Rises', 'durationSeconds': 9840.0},
        ],
        'isHost': true,
        'canPlayback': true,
        'participants': [
          {'id': 'viewer-alice', 'name': 'Alice', 'role': 'host', 'isHost': true, 'present': true},
        ],
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: UburoomRoomView())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Badges in header
      expect(find.text('Saved room'), findsOneWidget);
      expect(find.text('Private'), findsOneWidget);

      // Queue card header & Auto-queue badge
      expect(find.text('Queue (2)'), findsOneWidget);
      expect(find.text('Auto-queue'), findsOneWidget);

      // Queue items
      expect(find.text('1'), findsOneWidget);
      expect(find.text('The Dark Knight'), findsOneWidget);
      expect(find.text('Action · 2008 · 2:32:00'), findsOneWidget);

      expect(find.text('2'), findsOneWidget);
      expect(find.text('The Dark Knight Rises'), findsOneWidget);
      expect(find.text('2:44:00'), findsOneWidget);
    });

    testWidgets('UburoomRoomView displays Queue is empty for durable room with empty queue', (tester) async {
      final socket = _TestUburoomSocketService();
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth, viewerId: 'viewer-alice');
      addTearDown(provider.dispose);

      provider.setUburoomSessionForTest(
        roomId: 'uburoom-empty-queue',
        serverUrl: 'https://watch.example',
        token: 'mock-token',
      );
      provider.handleUburoomSnapshotForTest({
        'id': 'uburoom-empty-queue',
        'name': 'Empty Queue Lounge',
        'epoch': 'epoch-1',
        'revision': 1,
        'durable': true,
        'queue': <Map<String, dynamic>>[],
        'participants': [
          {'id': 'viewer-alice', 'name': 'Alice', 'role': 'host', 'isHost': true, 'present': true},
        ],
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: UburoomRoomView())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Queue (0)'), findsOneWidget);
      expect(find.text('Queue is empty'), findsOneWidget);
      expect(find.text('Auto-queue'), findsNothing);
    });

    testWidgets('UburoomLobby displays Private in room card subtitle when visibility is private', (tester) async {
      final socket = _TestUburoomSocketService();
      socket.roomsToReturn = [
        {
          'id': 'room-priv-1',
          'name': 'VIP Screening',
          'active': true,
          'visibility': 'private',
          'viewers': 2,
          'title': 'Dune',
        },
        {'id': 'room-pub-1', 'name': 'Public Screening', 'active': true, 'visibility': 'public', 'viewers': 3},
      ];
      socket.savedRoomsToReturn = [
        {'id': 'room-priv-2', 'name': 'Secret Archive', 'active': false, 'visibility': 'private'},
      ];
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth);
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: UburoomLobby())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Private active room subtitle includes 'Private' after status
      expect(find.text('Active room · Private · 2 watching · Dune · room-priv-1'), findsOneWidget);

      // Public active room subtitle does NOT include 'Private'
      expect(find.text('Active room · 3 watching · room-pub-1'), findsOneWidget);

      // Private saved room subtitle includes 'Private'
      expect(find.text('Saved room · Private · room-priv-2'), findsOneWidget);
    });

    testWidgets('UburoomRoomView tapping Next dispatches media.next via skipToNextInUburoom', (tester) async {
      final socket = _TestUburoomSocketService();
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth, viewerId: 'viewer-alice');
      addTearDown(provider.dispose);

      provider.setUburoomSessionForTest(
        roomId: 'uburoom-room-queue-test',
        serverUrl: 'https://watch.example',
        token: 'mock-token',
      );
      provider.handleUburoomSnapshotForTest({
        'id': 'uburoom-room-queue-test',
        'name': 'Queue Test Room',
        'epoch': 'epoch-1',
        'revision': 1,
        'durable': true,
        'state': {'paused': false, 'time': 100.0},
        'mediaId': 'plex-1',
        'title': 'Item 1',
        'durationSeconds': 7200.0,
        'queue': [
          {'id': 'q-next-1', 'mediaId': 'plex-2', 'title': 'Item 2', 'durationSeconds': 5000.0},
        ],
        'isHost': true,
        'canPlayback': true,
        'participants': [
          {'id': 'viewer-alice', 'name': 'Alice', 'role': 'host', 'isHost': true, 'present': true},
        ],
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: UburoomRoomView())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final nextButton = find.widgetWithText(OutlinedButton, 'Next');
      expect(nextButton, findsOneWidget);
      await tester.tap(nextButton);
      await tester.pumpAndSettle();

      expect(
        socket.requests.any((r) => r.$1 == 'command' && (r.$2?['command'] as Map?)?['action'] == 'media.next'),
        isTrue,
      );
    });

    testWidgets('UburoomRoomView tapping Remove from queue on a queue tile dispatches remove queue request', (
      tester,
    ) async {
      final socket = _TestUburoomSocketService();
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth, viewerId: 'viewer-alice');
      addTearDown(provider.dispose);

      provider.setUburoomSessionForTest(
        roomId: 'uburoom-room-queue-test',
        serverUrl: 'https://watch.example',
        token: 'mock-token',
      );
      provider.handleUburoomSnapshotForTest({
        'id': 'uburoom-room-queue-test',
        'name': 'Queue Test Room',
        'epoch': 'epoch-1',
        'revision': 1,
        'durable': true,
        'state': {'paused': false, 'time': 100.0},
        'mediaId': 'plex-1',
        'title': 'Item 1',
        'durationSeconds': 7200.0,
        'queue': [
          {'id': 'q-remove-1', 'mediaId': 'plex-2', 'title': 'Item 2', 'durationSeconds': 5000.0},
        ],
        'isHost': true,
        'canPlayback': true,
        'participants': [
          {'id': 'viewer-alice', 'name': 'Alice', 'role': 'host', 'isHost': true, 'present': true},
        ],
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: UburoomRoomView())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final removeBtn = find.byTooltip('Remove from queue');
      expect(removeBtn, findsOneWidget);
      await tester.tap(removeBtn);
      await tester.pumpAndSettle();

      expect(
        socket.requests.any(
          (r) => r.$1 == 'room.queue.command' && r.$2?['action'] == 'remove' && r.$2?['entryId'] == 'q-remove-1',
        ),
        isTrue,
      );
    });

    testWidgets('UburoomRoomView tapping Auto-queue chip dispatches auto queue request', (tester) async {
      final socket = _TestUburoomSocketService();
      final auth = _TestUburoomAuthService();
      final provider = WatchTogetherProvider(socketService: socket, authService: auth, viewerId: 'viewer-alice');
      addTearDown(provider.dispose);

      provider.setUburoomSessionForTest(
        roomId: 'uburoom-room-queue-test',
        serverUrl: 'https://watch.example',
        token: 'mock-token',
      );
      provider.handleUburoomSnapshotForTest({
        'id': 'uburoom-room-queue-test',
        'name': 'Queue Test Room',
        'epoch': 'epoch-1',
        'revision': 1,
        'durable': true,
        'autoQueue': true,
        'state': {'paused': false, 'time': 100.0},
        'mediaId': 'plex-1',
        'title': 'Item 1',
        'durationSeconds': 7200.0,
        'queue': [
          {'id': 'q-1', 'mediaId': 'plex-2', 'title': 'Item 2', 'durationSeconds': 5000.0},
        ],
        'isHost': true,
        'canPlayback': true,
        'participants': [
          {'id': 'viewer-alice', 'name': 'Alice', 'role': 'host', 'isHost': true, 'present': true},
        ],
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<WatchTogetherProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: UburoomRoomView())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final autoQueueChip = find.widgetWithText(FilterChip, 'Auto-queue');
      expect(autoQueueChip, findsOneWidget);
      await tester.tap(autoQueueChip);
      await tester.pumpAndSettle();

      expect(
        socket.requests.any(
          (r) => r.$1 == 'room.queue.command' && r.$2?['action'] == 'auto' && r.$2?['mode'] == 'off',
        ),
        isTrue,
      );
    });
  });
}

class _TestUburoomAuthService extends UburoomAuthService {
  @override
  String? get serverUrl => 'https://watch.example';

  @override
  Future<String?> getToken() async => 'mock-token';
}

class _TestUburoomSocketService extends UburoomSocketService {
  final requests = <(String, Map<String, dynamic>?)>[];
  List<Map<String, dynamic>> roomsToReturn = [];
  List<Map<String, dynamic>> savedRoomsToReturn = [];
  Map<String, dynamic>? roomSnapshotToReturn;

  @override
  UburoomConnectionState get state => UburoomConnectionState.connected;

  @override
  bool get isConnected => true;

  @override
  String get serverUrl => 'https://watch.example';

  @override
  String get token => 'mock-token';

  @override
  Future<UburoomResponse> request(
    Map<String, dynamic> message, {
    Duration timeout = const Duration(seconds: 12),
  }) async => framed(message, await answer(requestName(message), requestData(message)));

  /// Answers one request by its name (see uburoom_test_requests.dart).
  Future<UburoomResponse> answer(String name, [Map<String, dynamic>? data]) async {
    requests.add((name, data));
    if (name == 'rooms.list') {
      return UburoomResponse(id: requests.length, status: 200, value: {'rooms': roomsToReturn});
    }
    if (name == 'rooms.saved') {
      return UburoomResponse(
        id: requests.length,
        status: 200,
        value: {'rooms': savedRoomsToReturn, 'total': savedRoomsToReturn.length},
      );
    }
    if (name == 'join') {
      return UburoomResponse(
        id: requests.length,
        status: 200,
        value:
            roomSnapshotToReturn ??
            {
              'id': 'test-room-id',
              'epoch': 'epoch-1',
              'revision': 1,
              'state': {'paused': true},
            },
      );
    }
    if (name == 'room.reopen') {
      return UburoomResponse(id: requests.length, status: 200, value: {'status': 'reopened'});
    }
    return UburoomResponse(id: requests.length, status: 200, value: {'status': 'applied'});
  }
}
