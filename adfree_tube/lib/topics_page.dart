import 'package:flutter/material.dart';

import 'settings.dart';

/// Where the user picks the topics whose newest videos Home shows.
class TopicsPage extends StatefulWidget {
  const TopicsPage({super.key});

  /// Offered as one-tap picks; any words can be typed in too.
  static const suggestions = [
    'Music',
    'News',
    'Gaming',
    'Technology',
    'Football',
    'Cooking',
    'Movie trailers',
    'Podcasts',
    'Science',
    'Travel',
    'Comedy',
    'Fitness',
  ];

  @override
  State<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends State<TopicsPage> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _add(String topic) {
    final settings = AppSettings.instance;
    if (settings.addTopic(topic)) {
      _text.clear();
    } else if (topic.trim().isNotEmpty &&
        settings.topics.length >= AppSettings.maxTopics) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That\'s the most topics you can have. '
              'Remove one to add another.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Your topics')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final topics = settings.topics;
          final lower = topics.map((t) => t.toLowerCase()).toSet();
          final unused = TopicsPage.suggestions
              .where((s) => !lower.contains(s.toLowerCase()))
              .toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Home shows the newest videos about these each time you '
                'open the app.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _text,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Add a topic',
                  hintText: 'A subject, a channel, a game…',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Add',
                    icon: const Icon(Icons.add),
                    onPressed: () => _add(_text.text),
                  ),
                ),
                onSubmitted: _add,
              ),
              const SizedBox(height: 16),
              if (topics.isEmpty)
                Text('No topics yet.', style: theme.textTheme.bodySmall)
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in topics)
                      InputChip(
                        label: Text(t),
                        onDeleted: () => settings.removeTopic(t),
                        deleteButtonTooltipMessage: 'Remove $t',
                      ),
                  ],
                ),
              if (unused.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('Suggestions', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in unused)
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: Text(s),
                        onPressed: () => _add(s),
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
