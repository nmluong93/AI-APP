import 'package:flutter/material.dart';

import 'playback.dart';
import 'widgets.dart';

/// Button that shows the sleep timer countdown and opens the timer picker.
class SleepTimerButton extends StatelessWidget {
  final bool compact;

  const SleepTimerButton({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final c = PlaybackController.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final left = c.sleepRemaining;
        final active = left != null;
        if (compact) {
          return IconButton(
            tooltip: active ? 'Sleep timer: ${formatDuration(left)}' : 'Sleep timer',
            icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
            onPressed: () => showSleepTimerSheet(context),
          );
        }
        return FilledButton.tonalIcon(
          onPressed: () => showSleepTimerSheet(context),
          icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
          label: Text(active ? formatDuration(left) : 'Sleep timer'),
        );
      },
    );
  }
}

const _presets = [5, 10, 15, 30, 45, 60, 90, 120];

Future<void> showSleepTimerSheet(BuildContext context) {
  final c = PlaybackController.instance;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final left = c.sleepRemaining;
          return ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text('Pause playback after…',
                    style: Theme.of(context).textTheme.titleMedium),
                subtitle: left != null
                    ? Text('Pausing in ${formatDuration(left)}')
                    : null,
              ),
              if (left != null)
                ListTile(
                  leading: const Icon(Icons.timer_off_outlined),
                  title: const Text('Turn off timer'),
                  onTap: () {
                    c.cancelSleepTimer();
                    Navigator.pop(context);
                  },
                ),
              for (final m in _presets)
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(m < 60
                      ? '$m minutes'
                      : '${m ~/ 60} hour${m >= 120 ? 's' : ''}${m % 60 > 0 ? ' ${m % 60} min' : ''}'),
                  onTap: () {
                    c.setSleepTimer(Duration(minutes: m));
                    Navigator.pop(context);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Custom…'),
                onTap: () async {
                  final nav = Navigator.of(context);
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: const TimeOfDay(hour: 0, minute: 20),
                    initialEntryMode: TimePickerEntryMode.input,
                    helpText: 'Pause after (hours : minutes)',
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(alwaysUse24HourFormat: true),
                      child: child!,
                    ),
                  );
                  if (picked == null) return;
                  final d = Duration(hours: picked.hour, minutes: picked.minute);
                  if (d > Duration.zero) c.setSleepTimer(d);
                  nav.pop();
                },
              ),
            ],
          );
        },
      ),
    ),
  );
}
