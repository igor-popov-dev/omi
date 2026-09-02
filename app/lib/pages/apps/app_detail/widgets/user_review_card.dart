import 'package:flutter/material.dart';

import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:timeago/timeago.dart' as timeago;

import 'package:omi/backend/schema/app.dart';
import 'package:omi/widgets/extensions/string.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class UserReviewCard extends StatelessWidget {
  final AppReview review;
  final String ownerName;
  const UserReviewCard({super.key, required this.review, required this.ownerName});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Container(
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
                initialRating: review.score.toDouble(),
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
              Text(timeago.format(review.ratedAt), style: TextStyle(color: t.textSecondary, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          Text(review.review.decodeString, style: TextStyle(color: t.textPrimary)),
          const SizedBox(height: 16),
          review.response.isNotEmpty
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Divider(color: Color.fromARGB(255, 208, 207, 207)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(ownerName, style: TextStyle(color: t.textPrimary)),
                        const SizedBox(width: 8),
                        review.respondedAt != null
                            ? Text(
                                timeago.format(review.respondedAt!),
                                style: TextStyle(color: t.textSecondary, fontSize: 12),
                              )
                            : const SizedBox(),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(review.response, style: TextStyle(color: t.textPrimary)),
                  ],
                )
              : const SizedBox(),
        ],
      ),
    );
  }
}
