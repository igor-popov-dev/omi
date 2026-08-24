import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class PhotoViewerPage extends StatefulWidget {
  final List<ConversationPhoto> photos;
  final int initialIndex;

  const PhotoViewerPage({super.key, required this.photos, required this.initialIndex});

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late int currentIndex;
  late PageController pageController;

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex;
    pageController = PageController(initialPage: widget.initialIndex);
  }

  void onPageChanged(int index) {
    setState(() {
      currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    final currentPhoto = widget.photos[currentIndex];
    final hasDescription = currentPhoto.description != null && currentPhoto.description!.isNotEmpty;
    final isProcessing = currentPhoto.description == null;

    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.textPrimary),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PhotoViewGallery.builder(
                itemCount: widget.photos.length,
                pageController: pageController,
                onPageChanged: onPageChanged,
                builder: (context, index) {
                  final photo = widget.photos[index];
                  final imageBytes = base64Decode(photo.base64);
                  return PhotoViewGalleryPageOptions(
                    imageProvider: MemoryImage(imageBytes),
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 4,
                    heroAttributes: PhotoViewHeroAttributes(tag: photo.id),
                  );
                },
                scrollPhysics: const BouncingScrollPhysics(),
                backgroundDecoration: BoxDecoration(color: t.bgPrimary),
              ),
            ),
            if (currentPhoto.discarded)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                child: Text(
                  context.l10n.photoDiscardedMessage,
                  style: TextStyle(color: t.textPrimary.withValues(alpha: 0.7), fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              )
            else if (isProcessing)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: t.textPrimary.withValues(alpha: 0.7)),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      context.l10n.analyzing,
                      style: TextStyle(color: t.textPrimary.withValues(alpha: 0.7), fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else if (hasDescription)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                child: Text(
                  currentPhoto.description!,
                  style: TextStyle(color: t.textPrimary, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
