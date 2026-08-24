import 'dart:io';

import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:provider/provider.dart';

import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/share_links.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// Contact with phone number for sharing
class ShareableContact {
  final String id;
  final String displayName;
  final String phoneNumber;
  bool isSelected;

  ShareableContact({required this.id, required this.displayName, required this.phoneNumber, this.isSelected = false});
}

/// Show the share to contacts bottom sheet
void showShareToContactsBottomSheet(BuildContext context, ServerConversation conversation) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => ShareToContactsBottomSheet(conversation: conversation),
  );
}

/// Bottom sheet for selecting contacts and sharing conversation via native SMS
class ShareToContactsBottomSheet extends StatefulWidget {
  final ServerConversation conversation;

  const ShareToContactsBottomSheet({super.key, required this.conversation});

  @override
  State<ShareToContactsBottomSheet> createState() => _ShareToContactsBottomSheetState();
}

class _ShareToContactsBottomSheetState extends State<ShareToContactsBottomSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<ShareableContact> _contacts = [];
  List<ShareableContact> _filteredContacts = [];
  bool _isLoading = true;
  bool _isPreparingShare = false;
  String? _errorMessage;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    // Track sheet opened
    PlatformManager.instance.analytics.shareToContactsSheetOpened(widget.conversation.id);
    _loadContacts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _permissionDenied = false;
    });

    // Request contacts permission using flutter_contacts' own method
    final status = await FlutterContacts.permissions.request(PermissionType.readWrite);
    final permissionGranted = status == PermissionStatus.granted || status == PermissionStatus.limited;

    if (!permissionGranted) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _permissionDenied = true;
        _errorMessage = context.l10n.contactsPermissionRequiredForSms;
      });
      return;
    }

    try {
      // Fetch contacts with phone numbers
      final contacts = await FlutterContacts.getAll(properties: {ContactProperty.phone});

      // Filter contacts that have phone numbers and create ShareableContact list
      final shareableContacts = <ShareableContact>[];
      for (final contact in contacts) {
        for (final phone in contact.phones) {
          if (phone.number.isNotEmpty) {
            final displayName = contact.displayName;
            shareableContacts.add(
              ShareableContact(
                id: '${contact.id}_${phone.number}',
                displayName: displayName != null && displayName.isNotEmpty ? displayName : phone.number,
                phoneNumber: _cleanPhoneNumber(phone.number),
              ),
            );
          }
        }
      }

      // Sort by display name
      shareableContacts.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

      setState(() {
        _contacts = shareableContacts;
        _filteredContacts = shareableContacts;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '${context.l10n.failedToLoadContacts}: $e';
      });
    }
  }

  /// Clean phone number for SMS URI (remove spaces, dashes, etc.)
  String _cleanPhoneNumber(String phone) {
    return phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  }

  void _filterContacts(String query) {
    if (query.isEmpty) {
      setState(() {
        _filteredContacts = _contacts;
      });
      return;
    }

    final lowerQuery = query.toLowerCase();
    setState(() {
      _filteredContacts = _contacts.where((contact) {
        return contact.displayName.toLowerCase().contains(lowerQuery) || contact.phoneNumber.contains(query);
      }).toList();
    });
  }

  void _toggleContactSelection(ShareableContact contact) {
    setState(() {
      contact.isSelected = !contact.isSelected;
    });
    // Track selection changes
    final selectedCount = _selectedContacts.length;
    if (selectedCount > 0) {
      PlatformManager.instance.analytics.shareToContactsSelected(widget.conversation.id, selectedCount);
    }
  }

  List<ShareableContact> get _selectedContacts => _contacts.where((c) => c.isSelected).toList();

  Future<void> _openNativeSms() async {
    final selected = _selectedContacts;
    if (selected.isEmpty) return;

    final l10n = context.l10n;
    setState(() {
      _isPreparingShare = true;
      _errorMessage = null;
    });

    try {
      // First, set conversation to shared visibility
      final shared = await setConversationVisibility(widget.conversation.id);
      if (!shared) {
        if (!mounted) return;
        setState(() {
          _isPreparingShare = false;
          _errorMessage = l10n.failedToPrepareConversationForSharing;
        });
        return;
      }
      if (mounted) {
        context.read<ConversationDetailProvider>().updateVisibilityLocally(ConversationVisibility.shared);
      }

      // Build the share link and message
      final shareLink = conversationShareUrl(widget.conversation.id);
      final message = l10n.heresWhatWeDiscussed(shareLink);

      // Build recipients string (comma-separated phone numbers)
      final recipients = selected.map((c) => c.phoneNumber).join(',');

      // Build SMS URI
      // iOS uses & for body separator, Android uses ?
      final Uri smsUri;
      if (Platform.isIOS) {
        smsUri = Uri.parse('sms:$recipients&body=${Uri.encodeComponent(message)}');
      } else {
        smsUri = Uri.parse('sms:$recipients?body=${Uri.encodeComponent(message)}');
      }

      if (!mounted) return;

      // Launch native SMS app
      if (await canLaunchUrl(smsUri)) {
        // Track SMS opened
        PlatformManager.instance.analytics.shareToContactsSmsOpened(widget.conversation.id, selected.length);
        HapticFeedback.mediumImpact();
        if (mounted) {
          Navigator.of(context).pop();
        }
        await launchUrl(smsUri);
      } else {
        setState(() {
          _isPreparingShare = false;
          _errorMessage = l10n.couldNotOpenSmsApp;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isPreparingShare = false;
        _errorMessage = '${context.l10n.error}: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: t.bgSecondary,
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: t.textTertiary, borderRadius: BorderRadius.circular(2)),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          context.l10n.shareViaSms,
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: t.textPrimary),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: t.textSecondary),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.selectContactsToShareSummary,
                      style: TextStyle(fontSize: 14, color: t.textSecondary),
                    ),
                  ],
                ),
              ),
              // Search bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _searchController,
                  onChanged: _filterContacts,
                  style: TextStyle(color: t.textPrimary),
                  decoration: InputDecoration(
                    hintText: context.l10n.searchContactsHint,
                    hintStyle: TextStyle(color: t.textSecondary),
                    prefixIcon: Icon(Icons.search, color: t.textSecondary),
                    filled: true,
                    fillColor: t.bgTertiary,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(t.rowRadius), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Selected count
              if (_selectedContacts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: t.accent.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          context.l10n.contactsSelectedCount(_selectedContacts.length),
                          style: TextStyle(color: t.accent, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            for (var contact in _contacts) {
                              contact.isSelected = false;
                            }
                          });
                        },
                        child: Text(context.l10n.clearAllSelection, style: TextStyle(color: t.textSecondary)),
                      ),
                    ],
                  ),
                ),
              // Error message
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.error.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: t.error, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_errorMessage!, style: TextStyle(color: t.error, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ),
              // Contacts list
              Expanded(child: _buildContactsList(scrollController)),
              // Send button
              if (!_permissionDenied)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _selectedContacts.isEmpty || _isPreparingShare ? null : _openNativeSms,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: t.accent,
                          disabledBackgroundColor: t.textTertiary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.rowRadius)),
                        ),
                        child: _isPreparingShare
                            ? SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                                ),
                              )
                            : Text(
                                _selectedContacts.isEmpty
                                    ? context.l10n.selectContactsToShare
                                    : _selectedContacts.length > 1
                                        ? context.l10n.shareWithContactsCount(_selectedContacts.length)
                                        : context.l10n.shareWithContactCount(_selectedContacts.length),
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: t.textPrimary),
                              ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContactsList(ScrollController scrollController) {
    final t = context.omi;
    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: t.accent));
    }

    if (_permissionDenied) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.contacts, size: 64, color: t.textTertiary),
            const SizedBox(height: 16),
            Text(
              context.l10n.contactsPermissionRequired,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: t.textSecondary),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.grantContactsPermissionForSms,
              style: TextStyle(color: t.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () async {
                // Open app settings
                if (Platform.isIOS) {
                  await launchUrl(Uri.parse('app-settings:'));
                } else {
                  await launchUrl(Uri.parse('package:com.friend.ios'));
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: t.accent),
              child: Text(context.l10n.openSettings),
            ),
          ],
        ),
      );
    }

    if (_filteredContacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: t.textTertiary),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isEmpty
                  ? context.l10n.noContactsWithPhoneNumbers
                  : context.l10n.noContactsMatchSearch,
              style: TextStyle(fontSize: 16, color: t.textSecondary),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: _filteredContacts.length,
      itemBuilder: (context, index) {
        final contact = _filteredContacts[index];
        return _buildContactTile(contact);
      },
    );
  }

  Widget _buildContactTile(ShareableContact contact) {
    final t = context.omi;
    return ListTile(
      onTap: () => _toggleContactSelection(contact),
      leading: CircleAvatar(
        backgroundColor: contact.isSelected ? t.accent : t.textTertiary,
        child: contact.isSelected
            ? Icon(Icons.check, color: t.textPrimary, size: 20)
            : Text(
                contact.displayName.isNotEmpty ? contact.displayName[0].toUpperCase() : '?',
                style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold),
              ),
      ),
      title: Text(
        contact.displayName,
        style: TextStyle(color: t.textPrimary, fontWeight: contact.isSelected ? FontWeight.w600 : FontWeight.normal),
      ),
      subtitle: Text(contact.phoneNumber, style: TextStyle(color: t.textSecondary, fontSize: 12)),
      trailing: contact.isSelected
          ? Icon(Icons.check_circle, color: t.accent)
          : Icon(Icons.circle_outlined, color: t.textTertiary),
    );
  }
}
