import 'package:flutter/material.dart';

import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;

import 'package:omi/backend/http/api/apps.dart';
import 'package:omi/backend/schema/app.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/extensions/string.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class AppOwnerReviewCard extends StatefulWidget {
  final AppReview review;
  final String appId;
  final String ownerName;
  const AppOwnerReviewCard({super.key, required this.review, required this.appId, required this.ownerName});

  @override
  State<AppOwnerReviewCard> createState() => _AppOwnerReviewCardState();
}

class _AppOwnerReviewCardState extends State<AppOwnerReviewCard> {
  bool showReplyField = false;
  bool showButton = false;
  late TextEditingController replyController;
  bool isLoading = false;

  @override
  void initState() {
    replyController = TextEditingController();
    if (widget.review.response.isNotEmpty) {
      replyController.text = widget.review.response;
    }
    super.initState();
  }

  void updateShowButton(bool value) {
    setState(() {
      showButton = value;
    });
  }

  void updateShowReplyField(bool value) {
    setState(() {
      showReplyField = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return GestureDetector(
      onTap: () {
        FocusScope.of(context).unfocus();
      },
      child: Container(
        width: MediaQuery.of(context).size.width * 0.78,
        padding: const EdgeInsets.all(16.0),
        margin: const EdgeInsets.only(left: 12.0, right: 12.0, top: 2, bottom: 6),
        decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(16.0)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                RatingBar.builder(
                  initialRating: widget.review.score.toDouble(),
                  minRating: 1,
                  ignoreGestures: true,
                  direction: Axis.horizontal,
                  allowHalfRating: true,
                  itemCount: 5,
                  itemSize: 20,
                  tapOnlyMode: false,
                  itemPadding: const EdgeInsets.symmetric(horizontal: 0),
                  itemBuilder: (context, _) => Icon(Icons.star, color: t.textPrimary),
                  maxRating: 5.0,
                  onRatingUpdate: (rating) {},
                ),
                const SizedBox(width: 8),
                Text(timeago.format(widget.review.ratedAt), style: TextStyle(color: t.textSecondary, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 8),
            Text(widget.review.review.decodeString, style: TextStyle(color: t.textPrimary)),
            const SizedBox(height: 16),
            ClipRRect(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.only(top: 6),
                height: showReplyField ? MediaQuery.sizeOf(context).height * 0.21 : 0,
                child: isLoading
                    ? Center(
                        child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary)),
                      )
                    : (!showReplyField
                        ? null
                        : SingleChildScrollView(
                            physics: const NeverScrollableScrollPhysics(),
                            child: Column(
                              children: [
                                SizedBox(
                                  width: MediaQuery.sizeOf(context).width * 0.88,
                                  child: TextFormField(
                                    controller: replyController,
                                    enabled: isLoading ? false : true,
                                    keyboardType: TextInputType.multiline,
                                    maxLength: 250,
                                    onChanged: (value) {
                                      if (value.isEmpty) {
                                        if (value == widget.review.review) {
                                          updateShowButton(false);
                                        } else {
                                          updateShowButton(true);
                                        }
                                      } else {
                                        updateShowButton(true);
                                      }
                                    },
                                    decoration: InputDecoration(
                                      hintText: context.l10n.writeSomething,
                                      hintStyle: TextStyle(color: t.textSecondary),
                                      border: OutlineInputBorder(
                                        borderRadius: const BorderRadius.all(Radius.circular(8)),
                                        borderSide: BorderSide(color: t.textSecondary),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: const BorderRadius.all(Radius.circular(8)),
                                        borderSide: BorderSide(color: t.textTertiary),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: const BorderRadius.all(Radius.circular(8)),
                                        borderSide: BorderSide(color: t.textSecondary),
                                      ),
                                    ),
                                    style: TextStyle(color: t.textPrimary),
                                    maxLines: 3,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: MediaQuery.sizeOf(context).width * 0.36,
                                      child: OutlinedButton(
                                        style: OutlinedButton.styleFrom(
                                          side: BorderSide(color: (t.isGlass ? t.accent : Colors.white)),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                        ),
                                        onPressed: () {
                                          updateShowReplyField(false);
                                        },
                                        child: Text(
                                          context.l10n.cancel,
                                          style: TextStyle(color: t.textPrimary, fontSize: 16),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 30),
                                    SizedBox(
                                      width: MediaQuery.sizeOf(context).width * 0.36,
                                      child: OutlinedButton(
                                        style: OutlinedButton.styleFrom(
                                          side: BorderSide(color: (t.isGlass ? t.accent : Colors.white)),
                                          backgroundColor: (t.isGlass ? t.accent : Colors.white),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                        ),
                                        onPressed: () async {
                                          if (replyController.text.isNotEmpty) {
                                            setState(() {
                                              isLoading = true;
                                            });
                                            await replyToAppReview(
                                              widget.appId,
                                              replyController.text,
                                              widget.review.uid,
                                            );
                                            if (context.mounted) {
                                              context.read<AppProvider>().updateLocalAppReviewResponse(
                                                    widget.appId,
                                                    replyController.text,
                                                    widget.review.uid,
                                                  );
                                            }
                                            setState(() {
                                              widget.review.response = replyController.text;
                                              isLoading = false;
                                              showReplyField = false;
                                            });
                                          }
                                        },
                                        child: Text(
                                          context.l10n.submitReply,
                                          style:
                                              TextStyle(color: (t.isGlass ? t.onAccent : Colors.black), fontSize: 16),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          )),
              ),
            ),
            !showReplyField && widget.review.response.isNotEmpty
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Divider(color: Color.fromARGB(255, 208, 207, 207)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(widget.ownerName, style: TextStyle(color: t.textPrimary)),
                          const SizedBox(width: 8),
                          widget.review.respondedAt != null
                              ? Text(
                                  timeago.format(widget.review.respondedAt!),
                                  style: TextStyle(color: t.textSecondary, fontSize: 12),
                                )
                              : const SizedBox(),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(widget.review.response, style: TextStyle(color: t.textPrimary)),
                    ],
                  )
                : const SizedBox(),
            const SizedBox(height: 8),
            !showReplyField
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: (t.isGlass ? t.accent : Colors.white),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        onPressed: () {
                          updateShowReplyField(!showReplyField);
                        },
                        child: Text(
                          widget.review.response.isNotEmpty ? context.l10n.editYourReply : context.l10n.replyToReview,
                          style: TextStyle(color: (t.isGlass ? t.onAccent : Colors.black)),
                        ),
                      ),
                    ],
                  )
                : const SizedBox(),
          ],
        ),
      ),
    );
  }
}
