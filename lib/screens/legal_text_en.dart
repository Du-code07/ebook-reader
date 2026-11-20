// 이용 약관·개인정보 처리방침 영어 번역본 (참고용 — 한국어판이 우선)
// legal_screen.dart의 한국어 원문과 항목 순서·내용을 똑같이 맞춰 둘 것

const String legalBlankEn = '(to be added)';
const String _email = 'dudu.dev.pr@gmail.com';
const String _blank = legalBlankEn;

const List<(String, List<String>)> termsEn = [
  ('Article 1 (Purpose)', [
    'These Terms of Service (the "Terms") set out the rights, obligations and responsibilities between the developer of 이리ERI (the "Operator") and users of the app (the "Users") regarding the use of the mobile app 이리ERI (the "App").',
  ]),
  ('Article 2 (Definitions)', [
    '- "App" means the document viewer app "이리ERI" provided by the Operator through Google Play.',
    '- "User" means an individual who accesses or uses the App under these Terms.',
    '- "Paid Features" means additional or premium features that the Operator provides free of charge during the free period set out in Article 5 and intends to make available afterwards through a one-time in-app purchase made with the Google Play billing system.',
    '- "User Files" means documents, images and other files that a User adds to or opens with the App, and the notes, annotations and bookmarks a User creates in the App.',
  ]),
  ('Article 3 (Effect and Amendment of the Terms)', [
    'These Terms are posted in the help and settings screens of the App and take effect when a User installs, accesses or uses the App.',
    'The Operator may amend these Terms to the extent permitted by applicable law. When amending the Terms, the Operator will announce the effective date and the changes in the App and on the Google Play Store page from 7 days before the effective date.',
    'Changes that are unfavorable or material to Users will be announced from 30 days before the effective date and individually notified in a way Users can actually notice, such as a separate notice when the App is launched, and the Operator will obtain Users\' consent where required by applicable law.',
    'A User who does not agree to the amended Terms may stop using and delete the App. If a User does not agree to an unfavorable change, the previous Terms continue to apply to Paid Features already purchased.',
  ]),
  ('Article 4 (Services and Device Permissions)', [
    'The App lets Users open and view files in many formats on their device, including PDF, Hangul (HWP, HWPX), Word, PowerPoint, Excel, EPUB, TXT and image files, and provides tools such as notes, bookmarks, scanning and file merging.',
    'The basic features of the App are provided free of charge. Some advanced features are Paid Features, but under Article 5 the Paid Features are also provided free of charge to all Users until March 1, 2027.',
    'Because the App converts and displays documents on the User\'s device, fonts, formatting and layout may look different from the program that originally created the file.',
    'To provide its core features, the App uses access to files and folders chosen by the User (through the system file picker and Folders to Search) and some optional device permissions (camera access for document scanning, biometrics for unlocking, etc.). If a User does not allow an optional permission or access is restricted by changes in Android OS policy, the related feature may not work.',
  ]),
  ('Article 5 (Free Provision and Future Sale of Paid Features)', [
    'Free period: Until March 1, 2027 (through February 28, 2027), the Operator provides all Paid Features, such as Scan Document, Merge Images and Merge PDFs, free of charge to all Users. During this period the App accepts no payments, and the Operator earns no revenue of any kind, including sales, advertising or donations.',
    'Future sale: The Operator plans to sell the Paid Features as a one-time in-app purchase of "이리ERI Pro" after March 1, 2027. When sales begin, the Operator will announce amended Terms covering the sale (price, payment and restoring purchases, free trial, withdrawal and refunds) together with the Operator (seller) information required by applicable law, from 30 days before the effective date under Article 3.',
    'After sales begin, Users who have not purchased 이리ERI Pro may no longer be able to use the Paid Features. Even then, the basic features of the App, files created by scanning or merging during the free period, and User Files, notes and bookmarks remain available.',
    'The Operator may postpone the start of sales or extend the free period, in which case it will announce this in the App.',
  ]),
  ('Article 6 (Intellectual Property and Third-Party Services)', [
    'All intellectual property rights in the App, including copyrights, trademarks, source code, user interface designs and logos, belong to the Operator or to those who have licensed them to the Operator.',
    'The Operator grants Users a limited, non-exclusive, non-transferable and revocable right to install and use the App on their own devices solely for lawful personal or internal business purposes.',
    'The App uses third-party services (such as Google Play billing and Google ML Kit for text recognition) and open-source software libraries. These third-party services and open-source components are subject to their own terms and licenses, and Google ML Kit is not open source but an SDK subject to Google\'s separate terms of service. Licenses and notices can be found in the App under Settings > Help > Open Source Licenses.',
  ]),
  ('Article 7 (User Files and Personal Information)', [
    'All rights and ownership in User Files belong to the User or the original rights holder.',
    'The App processes documents on the User\'s device. The App does not send User Files to the Operator\'s servers or store them in a way the Operator can access.',
    'When using User Files, Users must not infringe the copyrights or other rights of third parties.',
    'User Files (including library copies and PDFs created by merging or scanning), notes and bookmarks are stored in the App\'s private storage on the User\'s device, so they are permanently deleted together with the App if the device is lost, damaged or reset, or if the App or its data is deleted (original files in folders such as Download are not deleted). Notes are stored separately in the App and do not change the original file, and scanning and merging create new files without changing the originals. Users are therefore advised to keep backups of important original files and PDFs created by scanning or merging by exporting them to device folders or external storage with the App\'s Share feature.',
    'The Operator is not responsible for file damage or saving failures caused, without the Operator\'s fault, by insufficient storage, battery depletion, unexpected system interruptions or the like.',
    'Because the password or pattern of the privacy lock is stored on the User\'s device only in a form that cannot be restored, the Operator cannot check or recover it. If a User forgets the password or pattern, the lock can only be removed by clearing the App data, which permanently deletes the library copies, notes, bookmarks and settings in the App.',
    'Details on the processing of personal information are set out in the App\'s Privacy Policy ($_blank).',
  ]),
  ('Article 8 (Prohibited Acts)', [
    'Users must not do any of the following:',
    '- Reverse engineer, decompile, disassemble, modify or redistribute the App, except where expressly permitted by applicable law or the relevant open-source license',
    '- Circumvent the payment system or attempt to use Paid Features without proper payment',
    '- Use the App for illegal purposes or in violation of applicable law',
    '- Interfere with the normal operation of the App or infringe the rights of the Operator or third parties',
  ]),
  ('Article 9 (Termination of Use)', [
    'Users may stop using the App at any time by deleting it from their device.',
    'If a User violates these Terms, the Operator may, with prior notice where possible, revoke the right of use granted under Article 6 and restrict or terminate the use of Paid Features through Google Play. In this case, matters relating to Paid Features are handled in accordance with applicable law.',
  ]),
  ('Article 10 (Changes to and Discontinuation of the Service)', [
    'The Operator may change or improve the App\'s features through App updates. Removing Paid Features already purchased or changing them to the disadvantage of Users follows the procedure in Article 3.',
    'If the Operator permanently discontinues the App, it will announce this in the App and on the Google Play Store page at least 30 days in advance.',
    'Even after discontinuation, the Operator will make efforts so that purchased Paid Features can continue to be used in already installed copies of the App, and if use of Paid Features or restoration of purchases becomes impossible, the Operator will provide a refund or compensation in accordance with applicable law.',
  ]),
  ('Article 11 (Scope of Liability)', [
    'Because the App converts and displays documents on the device, fonts, formatting and layout may look different from the original program, and text recognition results may contain errors depending on the shooting conditions.',
    'The Operator does not guarantee compatibility with every device or Android OS version.',
    'The Operator is not liable for damage caused by reasons not attributable to the Operator, such as natural disasters, device hardware failures, OS updates or errors, or reasons attributable to the User.',
    'If a defect in the App\'s core features caused by the Operator\'s intent or negligence results in damage to a User, the Operator is liable in accordance with applicable law.',
  ]),
  ('Article 12 (Governing Law, Dispute Resolution and Miscellaneous)', [
    'Governing law: These Terms are interpreted under the laws of the Republic of Korea. However, where mandatory consumer protection laws of the User\'s country of residence provide otherwise, those laws apply.',
    'Dispute resolution: Disputes relating to these Terms or the use of the App are resolved by the competent court under the Korean Civil Procedure Act, subject to the jurisdiction rules that apply to consumers.',
    'Severability: Even if some provisions of these Terms are found invalid or unenforceable, the remaining provisions remain in effect.',
    'Language: These Terms are written in Korean. Where a translation is provided and there is any difference between the Korean version and the translation, the Korean version prevails.',
  ]),
  ('Article 13 (Operator Information and Contact)', [
    'Questions, inquiries and requests regarding these Terms or the App can be sent to:',
    '- Operator: the developer of 이리ERI (individual)',
    '- Email: $_email',
    'Because the Operator earns no revenue from the App during the free period, it is not subject to business registration or mail-order business reporting. Before paid sales begin, the Operator will add the business information required by applicable law to this Article and announce it under Article 5.',
  ]),
];

const List<(String, List<String>)> privacyEn = [
  ('1. Overview', [
    'The developer of 이리ERI (the "Operator") values the personal information of users. 이리ERI (the "App") requires no sign-up or login, and the Operator does not run its own servers or collect personal information directly through the App. However, information processed by the Google SDKs included in the App (Google ML Kit in Section 4 and, after paid sales begin, Google Play billing in Section 5) and inquiry emails sent by users (Section 7) are handled as described in those sections.',
    'Viewing and converting documents, scanned images and text recognition (OCR) are processed on the user\'s device, and the App does not automatically send them to the Operator\'s servers or third parties. However, Google ML Kit included in the App may send technical information to Google as described in Section 4.',
    'When a user chooses to send files or text to another app with the Share feature, attaches files to an inquiry email, or uses the Android OS backup, the privacy policies of those apps and services apply to that transfer and storage.',
  ]),
  ('2. Information Stored on the Device', [
    'To provide its core features, the App stores the following data in its private storage on the user\'s device.',
    '- Library and reading data: copies of files added to the library, file names, groups, favorites, last read position, notes and bookmarks',
    '- App settings and user fonts: app settings (theme, language, display style, etc.), font files imported by the user, and the list of Folders to Search registered by the user',
    '- Privacy lock data: if the lock is turned on, the password or pattern is stored only as a salted hash, not as plain text.',
    '- Temporary cache files: page preview images and table-of-contents data created to open documents quickly',
    'The privacy lock only restricts viewing within the 이리ERI app screens and does not encrypt the document files themselves in device storage.',
    'If the Android system backup setting on the user\'s device is turned on, some app settings and library data may be included in the user\'s own Google Account backup through the Android OS.',
  ]),
  ('3. App Permissions and Purposes', [
    '- File and folder access: The App reads only files chosen by the user in the system file picker, files that another app shares or opens with the App and grants read access to, and folders (including subfolders) registered under App Settings > Folders to Search, and uses them only to open documents and font files or add them to the library. The App does not use the storage read permission or any permission to access all storage.',
    '- Camera (optional): Used only for document scanning; the App asks for permission the first time document scanning is used. Captured images are stored on the user\'s device and are not sent outside.',
    '- Biometrics (optional): Used to unlock the privacy lock. Fingerprint and face recognition data are processed by the Android OS, and the App does not receive them.',
    '- Internet: The App does not send the user\'s files or document content over the internet. However, the internet may be used by Google ML Kit in Section 4 to send technical information or, after paid sales begin, by Google Play billing in Section 5 to check purchases. The network state permission added by Google libraries is used only for these purposes.',
    'The App can be used without granting optional permissions, but features related to those permissions will not be available.',
  ]),
  ('4. Third-Party SDK: Google ML Kit', [
    'The App uses the Google ML Kit text recognition (Korean) SDK to find, copy or build tables of contents from text on image-based pages (scanned PDFs, images, image-only slides, etc.).',
    '- Processed on the device: The page images being read and the recognized text are processed only on the device and are not sent to Google.',
    '- What may be sent to Google: For maintaining SDK quality and diagnosing errors, device information (manufacturer, model, OS version, etc.), app information (package name, version), a per-installation identifier, API settings (image format, resolution, etc.), input and output sizes, feature and SDK versions, event types, error codes, and performance and usage statistics such as processing time. This does not mean that images or recognized text are sent.',
    '- When it is sent: The technical information above may be sent to Google during the initialization and use of the Google ML Kit SDK. Images and recognized text themselves are not sent.',
    '- Controller and policy: This information is processed by Google LLC on Google\'s global servers according to its own standards, and the Google Privacy Policy (https://policies.google.com/privacy) and the ML Kit Terms of Service apply. The Operator does not receive this information.',
    '- Retention period: As set out in the Google Privacy Policy and the ML Kit Terms of Service.',
    '- How to refuse and its effect: Users can reduce this processing by not using the features that find, copy or build tables of contents from text on image-based pages, and all other features of the App remain available.',
  ]),
  ('5. In-App Purchases', [
    'Until March 1, 2027, the Paid Features are provided free of charge and no payments are made in the App, so the payment and purchase information and the free trial record in this section are not processed. Once paid sales begin, they will be processed as follows, and this policy will be announced again under Section 12 beforehand.',
    'Purchases of 이리ERI Pro (Paid Features) are processed only through the Google Play billing system.',
    'Payment information (such as credit card numbers) is processed directly by Google, and the Operator does not receive or store it. To provide Paid Features and confirm purchases, the App processes the product ID, price, purchase state and purchase token (the purchase token is used only to ask Google Play to acknowledge the purchase and is not sent to the Operator).',
    '- Stored on the device: whether the purchase has been made (so Paid Features can be used without internet access) and the start date of the free trial. These are deleted when the data is cleared or the App is deleted, and the purchase can be restored with the same Google account.',
    '- The start date of the free trial is also recorded in the Block Store of Google Play services so that the trial is not repeated on the same device. This value contains only the start date and time and is not sent to the Operator. The App does not request a cloud backup of this value, but it may be moved to a new device if the user performs a device transfer or restore with a Google account or a manufacturer tool (e.g. Samsung Smart Switch). It may remain on the same device even if the App or its data is deleted, and it is deleted when the device is reset.',
  ]),
  ('6. Sharing with Third Parties, Advertising and Cookies', [
    '- The Operator does not sell users\' personal information and does not provide it to third parties except where required by law or with the user\'s consent.',
    '- The external services used for the App and its operation are as follows. The Operator discloses this processing both in this policy and in the Google Play Data safety section.',
    '  · Google ML Kit (Google LLC): processing of the device and app information, per-installation identifier, and performance and usage information in Section 4',
    '  · Google Play billing (Google LLC): payment and purchase status checks in Section 5 (only after paid sales begin)',
    '  · Inquiry email service: Gmail (Google LLC) (receiving and storing the inquiry information in Section 7)',
    '- Information through Google ML Kit and Google Play billing is processed directly by Google LLC under the terms of each service and the Google Privacy Policy (Sections 4 and 5).',
    '- Overseas storage of inquiry emails: Because the Operator uses Gmail by Google LLC to receive inquiries, the inquiry information in Section 7 is stored on Google\'s servers outside Korea. Details are as follows.',
    '  · Recipient and contact: Google LLC (1600 Amphitheatre Parkway, Mountain View, CA 94043, USA / privacy inquiries: https://support.google.com/policies/contact/general_privacy_form)',
    '  · Countries of storage: the United States and other countries where Google operates data centers (data center locations: https://datacenters.google/locations/)',
    '  · Time and method of transfer: Sent over the internet and stored when the user sends an inquiry email. Whether the transmission is encrypted may depend on the email service the user uses.',
    '  · Items transferred: the inquiry information in Section 7 (email address, inquiry subject and content, attached files, and app version and device information if the user chooses to include them)',
    '  · Purpose of use and retention period: Same as Section 7.',
    '  · How to refuse and its effect: Nothing is transferred if the user does not send an inquiry by email. In that case, however, the user cannot receive an email response.',
    '- The App contains no advertising SDKs, and the Operator does not use separate usage analytics or tracking tools.',
    '- The App does not use cookies or automated behavioral tracking technologies to track users.',
    '- Document screens (EPUB, etc.) do not load images, fonts, styles or other content from external internet addresses written in the document. External links in a document open in the device\'s browser or another app only when the user taps them, after which the policies of that website or app apply.',
  ]),
  ('7. Information Received by Inquiry Email', [
    'If a user makes an inquiry by email (Help > Contact Us in the App opens the user\'s email app to send the email), the Operator processes the following information.',
    '- Items: email address, inquiry subject and content, files attached by the user, and (if the user chooses to include them on the Contact Us screen) app version, device manufacturer and model, and Android version',
    '- Purpose: responding to inquiries and checking and fixing errors',
    '- Retention period: Destroyed after being kept for 1 year after the inquiry is resolved (records of consumer complaints and dispute handling received after paid sales begin are kept for 3 years under the Korean Act on the Consumer Protection in Electronic Commerce). If the user requests deletion, the information is destroyed without delay unless the law requires it to be kept.',
    '- Method of destruction: When the retention period ends or a deletion request is received, the Operator deletes the relevant emails from the Gmail inbox and sent folder, empties the trash, and also deletes any attachments downloaded to the Operator\'s devices. Final deletion from Google\'s internal backups may take some time according to Google\'s deletion process.',
  ]),
  ('8. Security Measures', [
    '- App private storage: App data, notes and settings are stored in Android\'s isolated app-private storage, which other apps cannot access.',
    '- Hashed storage: The privacy lock password and pattern are stored as a salted one-way hash and never as plain text.',
  ]),
  ('9. Retention Period and Scope of Deletion', [
    'The Operator does not store app usage data such as documents, notes and settings on its servers. Information received by inquiry email is handled according to Section 7. Data on the device is kept until the user deletes it, and what is deleted depends on how it is deleted.',
    '- Clear cache (App Settings): Deletes only temporary files such as page previews and tables of contents. The library, notes, bookmarks and settings remain.',
    '- Clear data (App Settings or device settings) or uninstalling the App: Permanently deletes the library list, document copies, PDFs created by merging or scanning, notes, bookmarks, settings and lock data in the App\'s private storage.',
    '- Not deleted by the above: original files in shared storage such as the Download folder, copies sent to other apps with the Share feature, Google Account backups managed by Android, and the free trial start record in Section 5 (Google Play services Block Store, deleted when the device is reset). These must be deleted directly in the relevant app, file manager or the device\'s backup settings.',
  ]),
  ('10. Children\'s Personal Information', [
    'The Operator does not collect personal information through the App. However, if a child under 14 provides personal information, such as through an email inquiry, the Operator obtains and verifies the consent of the legal representative in accordance with the Korean Personal Information Protection Act.',
  ]),
  ('11. Users\' Rights', [
    '- Users can delete app data on the device at any time using the methods in Section 9.',
    '- Users can turn off or withdraw the camera permission in the device\'s system settings, biometric unlocking in App Settings > General > Privacy > Use Biometrics, and registered folders in App Settings > Folders to Search at any time.',
    '- For information provided by inquiry email, users may request access, correction, deletion or suspension of processing, or withdraw consent. If a request is sent to the email address in Section 12, the Operator will process it without delay (within 10 days at the latest) after verifying the user\'s identity and notify the user of the result.',
    '- However, information that must be kept under other laws (e.g. records of consumer complaints and dispute handling related to e-commerce) cannot be deleted or have its processing suspended during that period, and in that case the Operator will explain the reason.',
    '- To report or consult on a personal information infringement, users can contact the Personal Information Infringement Report Center (118 in Korea, privacy.kisa.or.kr) or the Personal Information Dispute Mediation Committee (1833-6972, www.kopico.go.kr).',
  ]),
  ('12. Changes to this Policy and Contact', [
    'If this policy changes, the effective date and the changes will be announced in the App and on the Google Play Store page from 7 days before the effective date (from 30 days before for changes that are material to users).',
    '- Operator: the developer of 이리ERI (individual)',
    '- Privacy officer: $_blank',
    '- Email: $_email',
    '- Public web address: $_blank',
  ]),
];
