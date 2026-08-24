import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/widgets/photo_viewer_page.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class PhotosGridComponent extends StatelessWidget {
  final List<ConversationPhoto> photos;
  const PhotosGridComponent({super.key, required this.photos});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return GridView.builder(
      padding: EdgeInsets.zero,
      scrollDirection: Axis.vertical,
      itemCount: photos.length,
      itemBuilder: (context, idx) {
        final photo = photos[idx];
        final isProcessing = !photo.discarded && photo.description == null;

        return GestureDetector(
          key: ValueKey(photo.id),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => PhotoViewerPage(photos: photos, initialIndex: idx),
              ),
            );
          },
          child: Hero(
            tag: photo.id,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    base64Decode(photo.base64),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    color: photo.discarded ? t.bgTertiary : null,
                    colorBlendMode: photo.discarded ? BlendMode.saturation : null,
                  ),
                  if (photo.discarded)
                    Container(
                      color: t.bgPrimary.withValues(alpha: 0.5),
                      child: Icon(Icons.visibility_off_outlined, color: t.textPrimary.withValues(alpha: 0.7), size: 28),
                    ),
                  if (isProcessing)
                    Container(
                      color: t.bgPrimary.withValues(alpha: 0.5),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 800 / 600,
      ),
    );
  }
}
