import 'package:flutter/material.dart';

import 'downloader.dart';
import 'downloads_page.dart';

/// App bar button that opens [DownloadsPage], with a badge counting the
/// downloads still running.
class DownloadsButton extends StatelessWidget {
  const DownloadsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final d = Downloader.instance;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) => IconButton(
        tooltip: 'Downloads',
        icon: Badge(
          isLabelVisible: d.activeCount > 0,
          label: Text('${d.activeCount}'),
          child: const Icon(Icons.download),
        ),
        onPressed: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
      ),
    );
  }
}
