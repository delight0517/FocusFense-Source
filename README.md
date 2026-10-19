# FocusFense source

FocusFense is a cross-platform app for managing website, app, browser, and time-use rules. This repository contains the application source snapshot corresponding to version 1.0.0+572.

## License and commercial restrictions

The FocusFense project code in this repository is offered under the PolyForm Noncommercial License 1.0.0. You may use, study, modify, and redistribute it for permitted noncommercial purposes, subject to the license. Commercial use, commercial distribution, and commercial modifications are not permitted without separate written permission from the relevant rights holders.

This is source-available software with a noncommercial restriction; it is not OSI-approved open-source software. The Open Source Initiative's definition does not allow restrictions on fields of endeavor such as business use.

The license applies only to material whose rights are held by the FocusFense project contributors. Third-party packages, platform SDKs, fonts, data, and browser-store artifacts remain under their respective licenses and terms. See mobile/pubspec.yaml and mobile/pubspec.lock for package declarations. Review third-party terms before redistributing a build.

For commercial licensing inquiries, contact the project owner through the FocusFense public project page.

## Build

Install a Flutter SDK compatible with the Dart constraint in mobile/pubspec.yaml, then run:

    cd mobile
    flutter pub get
    flutter run -d windows

Other Flutter targets are available where their platform SDKs are installed. Platform-specific signing and browser-store publishing require the developer's own accounts and credentials.

The Mozilla extension account is configurable at build time with FOCUSFENSE_MOZILLA_ACCOUNT. For example:

    flutter build windows --dart-define=FOCUSFENSE_MOZILLA_ACCOUNT=your-account@example.com

Never commit Mozilla issuer/secret values, signing keys, personal tokens, generated local environment files, or user profiles. The repository intentionally omits machine-local Flutter configuration.

## Contributions

Contributions are welcome for noncommercial development. By submitting a contribution, you agree that it may be distributed under the repository's PolyForm Noncommercial License 1.0.0. Do not submit third-party code unless its license permits inclusion under these terms; add attribution and license details when required.

## Korean

FocusFense 소스는 PolyForm Noncommercial 1.0.0에 따라 비상업적 목적으로 사용할 수 있습니다. 상업적 이용, 판매, 상업적 배포 및 상업적 개조는 별도 서면 허가 없이는 허용되지 않습니다. 이 조건 때문에 OSI가 정의하는 오픈소스가 아니라 비상업 조건이 붙은 소스 공개 소프트웨어입니다. 서드파티 구성요소에는 각각의 라이선스가 별도로 적용됩니다.
