import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class HowItWorksScreen extends StatelessWidget {
  const HowItWorksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final bool win = Platform.isWindows;
    final String title = win ? '차단 작동 방식' : '브라우저 작동 방식';
    final String s1 = win ? '1) 검색 화면 예시 (전)' : '1) 브라우저에서 이렇게 차단됨 (전)';
    final String s2 = win ? '2) 검색 화면 예시 (후)' : '2) 브라우저에서 이렇게 차단됨 (후)';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: win
                  ? const <Widget>[
                      Chip(avatar: Icon(Icons.desktop_windows, size: 16), label: Text('Windows')),
                      Chip(avatar: Icon(Icons.language, size: 16), label: Text('Chrome · Edge · Firefox')),
                      Chip(avatar: Icon(Icons.dns_outlined, size: 16), label: Text('시스템 DNS')),
                    ]
                  : const <Widget>[
                      Chip(avatar: Icon(Icons.language, size: 16), label: Text('브라우저 확장')),
                      Chip(avatar: Icon(Icons.vpn_lock_outlined, size: 16), label: Text('전체 VPN 아님')),
                      Chip(avatar: Icon(Icons.link_off, size: 16), label: Text('별도 연결 없음')),
                    ],
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: s1,
            child: _GoogleGrid(before: true, isWindows: win),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: s2,
            child: _GoogleGrid(before: false, isWindows: win),
          ),
          const SizedBox(height: 12),
          const _SectionCard(
            title: '3) 사용 순서 (3초)',
            child: _FlowRow(),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: '4) 어디서 작동하나요?',
            child: _ScopeRowDetailed(isWindows: win),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _GoogleGrid extends StatelessWidget {
  const _GoogleGrid({required this.before, required this.isWindows});

  final bool before;
  final bool isWindows;

  @override
  Widget build(BuildContext context) {
    final String searchCaption =
        isWindows ? '브라우저 이미지 검색' : '모바일 브라우저 이미지 검색';
    return Column(
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F6FD),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.search, size: 18, color: AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                      searchCaption,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 6,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1,
          ),
          itemBuilder: (BuildContext context, int index) {
            final bool blocked = !before && (index == 1 || index == 4);
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: blocked ? const Color(0xFFFDEBEC) : const Color(0xFFDFF5F2),
              ),
              child: blocked
                  ? const Center(
                      child: Icon(Icons.block, color: AppColors.danger),
                    )
                  : const Center(
                      child: Icon(Icons.image_outlined, color: AppColors.ink),
                    ),
            );
          },
        ),
      ],
    );
  }
}

class _FlowRow extends StatelessWidget {
  const _FlowRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Expanded(child: _FlowStep(icon: Icons.playlist_add, label: '단어 추가')),
        const Icon(Icons.arrow_forward, color: AppColors.muted),
        const Expanded(child: _FlowStep(icon: Icons.shield, label: '잠금 ON')),
        const Icon(Icons.arrow_forward, color: AppColors.muted),
        const Expanded(child: _FlowStep(icon: Icons.visibility_off, label: '이미지 숨김')),
      ],
    );
  }
}

class _FlowStep extends StatelessWidget {
  const _FlowStep({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.accent.withValues(alpha: 0.15),
          child: Icon(icon, size: 18, color: AppColors.ink),
        ),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _ScopeRowDetailed extends StatelessWidget {
  const _ScopeRowDetailed({required this.isWindows});

  final bool isWindows;

  @override
  Widget build(BuildContext context) {
    final String worksWhere =
        isWindows ? 'Chrome / Edge / Firefox' : '설치된 브라우저';
    final String step3 = '3) 브라우저에서 테스트 (별도 VPN 연결 없음)';
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFDFF5F2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: <Widget>[
                    const Icon(Icons.check_circle, color: Colors.green),
                    const SizedBox(height: 6),
                    Text(worksWhere),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFDEBEC),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Column(
                  children: <Widget>[
                    Icon(Icons.close, color: AppColors.danger),
                    SizedBox(height: 6),
                    Text('전체 VPN 아님'),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F6FD),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('연결 방법', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('1) 앱에서 규칙 추가'),
              const Text('2) 규칙 적용 버튼 누르기'),
              Text(step3),
            ],
          ),
        ),
      ],
    );
  }
}
