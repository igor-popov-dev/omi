import 'dart:io';

import 'package:flutter/material.dart';

import 'package:cached_network_image/cached_network_image.dart';

import 'package:omi/backend/schema/message.dart';
import 'package:omi/pages/chat/widgets/voice_message_widget.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class FilesHandlerWidget extends StatelessWidget {
  final ServerMessage message;
  final Function(String)? onAskOmi;
  const FilesHandlerWidget({super.key, required this.message, this.onAskOmi});

  bool _isLocalPath(String? path) {
    if (path == null || path.isEmpty) return false;
    return path.startsWith('/') || path.startsWith('file://');
  }

  @override
  Widget build(BuildContext context) {
    if (message.files.isEmpty || message.filesId.isEmpty) {
      return const SizedBox.shrink();
    }
    // Spoken assistant replies get a real player (voice_message_widget.dart)
    // instead of the generic "document" tile; other attachments keep the strip.
    final audioFiles = message.files.where((file) => file.isAudio).toList();
    final otherFiles = message.files.where((file) => !file.isAudio).toList();
    if (audioFiles.isEmpty) return _buildStrip(context, otherFiles);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final file in audioFiles) VoiceMessageWidget(message: message, file: file, onAskOmi: onAskOmi),
        if (otherFiles.isNotEmpty) _buildStrip(context, otherFiles),
      ],
    );
  }

  Widget _buildStrip(BuildContext context, List<MessageFile> files) {
    {
      final t = context.omi;
      return SizedBox(
        width: MediaQuery.sizeOf(context).width * 0.9,
        height: MediaQuery.sizeOf(context).height * 0.12,
        child: ListView.separated(
          itemCount: files.length,
          shrinkWrap: true,
          reverse: true,
          scrollDirection: Axis.horizontal,
          separatorBuilder: (context, index) {
            return const SizedBox(width: 6);
          },
          itemBuilder: (context, index) {
            if (files[index].mimeTypeToFileType() == 'image') {
              return _buildImageThumbnail(context, files[index]);
            } else {
              return Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor,
                  borderRadius: const BorderRadius.all(Radius.circular(10.0)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                margin: const EdgeInsets.only(bottom: 6, top: 2),
                width: MediaQuery.sizeOf(context).width * 0.32,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.insert_drive_file, color: t.textPrimary),
                    const SizedBox(height: 6),
                    Text(
                      files[index].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.textPrimary, fontSize: 14),
                    ),
                  ],
                ),
              );
            }
          },
        ),
      );
    }
  }

  Widget _buildImageThumbnail(BuildContext context, MessageFile file) {
    final t = context.omi;
    final thumbnail = file.thumbnail;
    final width = MediaQuery.sizeOf(context).width * 0.28;
    final height = MediaQuery.sizeOf(context).width * 0.22;

    if (_isLocalPath(thumbnail)) {
      final filePath = thumbnail!.startsWith('file://') ? thumbnail.substring(7) : thumbnail;
      return Container(
        margin: const EdgeInsets.only(bottom: 6, top: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor,
          borderRadius: const BorderRadius.all(Radius.circular(10.0)),
          image: DecorationImage(image: FileImage(File(filePath)), fit: BoxFit.cover),
        ),
        width: width,
        height: height,
      );
    }

    return CachedNetworkImage(
      imageUrl: thumbnail ?? '',
      imageBuilder: (context, imageProvider) => Container(
        margin: const EdgeInsets.only(bottom: 6, top: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor,
          borderRadius: const BorderRadius.all(Radius.circular(10.0)),
          image: DecorationImage(image: imageProvider, fit: BoxFit.cover),
        ),
        width: width,
        height: height,
      ),
      placeholder: (context, url) => SizedBox(
        width: width,
        height: height,
        child: Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary))),
      ),
      errorWidget: (context, url, error) => Container(
        margin: const EdgeInsets.only(bottom: 6, top: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor,
          borderRadius: const BorderRadius.all(Radius.circular(10.0)),
        ),
        width: width,
        height: height,
        child: Center(child: Icon(Icons.image, color: t.textPrimary.withValues(alpha: 0.54))),
      ),
    );
  }
}
