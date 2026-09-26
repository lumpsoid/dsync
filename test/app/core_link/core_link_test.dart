import 'package:dsync/app/core_link/core_link.dart';
import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/run_intent.dart';
import 'package:dsync/app/core_link/models/run_phase.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/core_link/models/run_view.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

import '../features/run/run_fixtures.dart';
import '../support/fake_hub.dart';

/// The [CoreLink] the head's controller tests run on, over the fake hub:
/// a session's snapshots reach its own stream, decoded by the link the app
/// runs, and end with the one the hub marks its last.
void main() {
  test('a run session\'s views are the hub\'s snapshots, decoded, and '
      'its intents are sent as they are', () async {
    final hub = FakeHub();
    final link = CoreLink(hub);
    final run = await link.startRun(
      const DraftTarget(
        ProfileDraft(localRoot: '/a', peerDeviceId: 'x', remoteRoot: '/b'),
      ),
      dryRun: false,
    );
    final views = <RunView>[];
    final listening = run.views.listen(views.add);
    hub.emitRun(run.session, runView(phase: reviewing(apply: 2)), last: false);
    await link.steerRun(
      run.session,
      const ChooseAction(1, ActionChoice.skipped),
    );
    await link.steerRun(run.session, const ConfirmReview());
    await Future<void>.delayed(Duration.zero);

    expect(views.single.phase, isA<RunReviewing>());
    expect((views.single.phase as RunReviewing).summary.apply, 2);
    expect(
      [for (final steer in hub.sent<wire.CoreCommandSteerRun>()) steer.intent],
      const [
        wire.RunIntentChooseAction(
          index: 1,
          choice: wire.ActionChoiceView.skipped,
        ),
        wire.RunIntentConfirm(),
      ],
    );

    // Once nobody listens, the session is forgotten: what arrives for it
    // is dropped.
    await listening.cancel();
    hub.emitRun(run.session, runView(phase: applying), last: false);
    await Future<void>.delayed(Duration.zero);
    expect(views, hasLength(1));
  });

  test('a session\'s stream ends with the snapshot the hub marks its '
      'last, and nothing after it is seen', () async {
    final hub = FakeHub();
    final link = CoreLink(hub);
    final run = await link.startRun(
      const DraftTarget(
        ProfileDraft(localRoot: '/a', peerDeviceId: 'x', remoteRoot: '/b'),
      ),
      dryRun: false,
    );
    final views = run.views.toList();
    hub
      ..emitRun(run.session, runView(phase: applying), last: false)
      ..emitRun(
        run.session,
        runView(standing: over, phase: finished()),
        last: true,
      )
      ..emitRun(run.session, runView(phase: connecting), last: false);

    final seen = await views;
    expect(
      [for (final view in seen) view.phase.runtimeType],
      [RunApplying, RunFinished],
    );
  });
}
