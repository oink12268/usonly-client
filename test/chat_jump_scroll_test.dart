// 채팅 검색 결과 → 해당 메시지로 이동하는 스크롤 로직 검증.
//
// ChatPage 자체는 Firebase/WebSocket/네트워크에 묶여 있어 위젯 테스트로 띄우기 어렵다.
// 대신 chat_page.dart의 채팅 리스트와 동일한 구조(reverse: true + 높이가 제각각인
// ListView.builder)를 재현해서, 이동 로직이 기대는 전제와 보정 방식이 실제로 성립하는지
// 확인한다.
//
// 리스트 인덱스 규약은 chat_page.dart와 동일:
//   ListView index 0 = 가장 최신 메시지(화면 맨 아래, offset 0)
//   index가 커질수록 오래된 메시지 = offset이 커진다

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const double _viewportHeight = 600;
const int _itemCount = 100;

/// 높이가 제각각인 채팅 버블 흉내 (사진 200 / 긴 글 120 / 한 줄 48)
double _heightFor(int index) {
  if (index % 7 == 0) return 200; // 사진
  if (index % 3 == 0) return 120; // 여러 줄
  return 48; // 한 줄
}

class _ChatListHarness extends StatefulWidget {
  final ScrollController controller;
  final GlobalKey targetKey;
  final int targetIndex;

  const _ChatListHarness({
    required this.controller,
    required this.targetKey,
    required this.targetIndex,
  });

  @override
  State<_ChatListHarness> createState() => _ChatListHarnessState();
}

class _ChatListHarnessState extends State<_ChatListHarness> {
  /// 링크 미리보기처럼 나중에 높이가 확정되는 아이템 (index → 늘어날 높이)
  final Map<int, double> _lateGrowth = {};

  /// 로딩이 끝나 미리보기 카드가 펼쳐진 상황을 재현
  void growLate(int index, double extra) {
    setState(() => _lateGrowth[index] = extra);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: _viewportHeight,
          child: ListView.builder(
            controller: widget.controller,
            reverse: true,
            // chat_page.dart가 하이라이트 중에 쓰는 값과 동일
            cacheExtent: 20000,
            itemCount: _itemCount,
            itemBuilder: (context, index) {
              return SizedBox(
                key: index == widget.targetIndex
                    ? widget.targetKey
                    : ValueKey('item_$index'),
                height: _heightFor(index) + (_lateGrowth[index] ?? 0),
                child: Text('msg $index'),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// chat_page.dart의 _centerOnTargetMessage와 동일한 보정 로직
void centerOnTarget(ScrollController controller, GlobalKey targetKey) {
  final renderObject = targetKey.currentContext?.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.attached) return;
  final viewport = RenderAbstractViewport.maybeOf(renderObject);
  if (viewport == null) return;

  final position = controller.position;
  final revealed = viewport
      .getOffsetToReveal(renderObject, 0.5)
      .offset
      .clamp(position.minScrollExtent, position.maxScrollExtent);
  if ((revealed - position.pixels).abs() < 1.0) return;
  controller.jumpTo(revealed);
}

/// 타겟 위젯의 중심이 뷰포트 중심에서 얼마나 벗어나 있는지(px)
double offCenterBy(GlobalKey targetKey) {
  final box = targetKey.currentContext!.findRenderObject() as RenderBox;
  final topLeft = box.localToGlobal(Offset.zero);
  final center = topLeft.dy + box.size.height / 2;
  return (center - _viewportHeight / 2).abs();
}

/// 타겟이 화면 안에 실제로 보이는지
bool targetIsVisible(GlobalKey targetKey) {
  final box = targetKey.currentContext!.findRenderObject() as RenderBox;
  final top = box.localToGlobal(Offset.zero).dy;
  return top < _viewportHeight && top + box.size.height > 0;
}

void main() {
  // 검색 결과로 이동할 때 chat_page.dart가 쓰는 인덱스 비율 점프.
  // 타겟은 older의 마지막이므로 ListView index = newerCount.
  double ratioOffset(ScrollController c, int targetIndex) {
    final p = c.position;
    return (p.maxScrollExtent * (targetIndex / _itemCount))
        .clamp(p.minScrollExtent, p.maxScrollExtent);
  }

  testWidgets('reverse 리스트에서 offset은 인덱스에 비례한다 (비율 방향 검증)',
      (tester) async {
    final controller = ScrollController();
    final targetKey = GlobalKey();
    await tester.pumpWidget(_ChatListHarness(
      controller: controller,
      targetKey: targetKey,
      targetIndex: 5,
    ));

    // 최신 메시지 쪽(index 5)의 정확한 위치
    centerOnTarget(controller, targetKey);
    await tester.pump();
    final correctOffset = controller.position.pixels;

    // 수정한 공식: index / N
    final fixed = ratioOffset(controller, 5);
    // 수정 전 공식: 1 - index / N
    final p = controller.position;
    final broken = (p.maxScrollExtent * (1 - 5 / _itemCount))
        .clamp(p.minScrollExtent, p.maxScrollExtent);

    expect((fixed - correctOffset).abs(), lessThan(_viewportHeight),
        reason: '수정된 비율은 타겟에서 한 화면 안쪽이어야 한다');
    expect((broken - correctOffset).abs(), greaterThan(_viewportHeight * 5),
        reason: '기존 공식은 정반대 끝으로 점프했다');
  });

  testWidgets('비율 점프만으로는 타겟이 화면 밖에 남는다 → 렌더 위치 보정 필요',
      (tester) async {
    final controller = ScrollController();
    final targetKey = GlobalKey();
    const targetIndex = 50;
    await tester.pumpWidget(_ChatListHarness(
      controller: controller,
      targetKey: targetKey,
      targetIndex: targetIndex,
    ));

    controller.jumpTo(ratioOffset(controller, targetIndex));
    await tester.pump();

    // 비율만으로는 어긋난다 (버블 높이가 제각각이라 균등 분포 가정이 깨짐)
    expect(offCenterBy(targetKey), greaterThan(50),
        reason: '비율 추정만으로는 중앙에 오지 않는다');

    // 보정 후에는 정확히 중앙
    centerOnTarget(controller, targetKey);
    await tester.pump();
    expect(offCenterBy(targetKey), lessThan(1.0));
    expect(targetIsVisible(targetKey), isTrue);
  });

  testWidgets('타겟보다 아래(더 최신) 메시지 높이가 나중에 늘면 타겟이 밀려난다',
      (tester) async {
    final controller = ScrollController();
    final targetKey = GlobalKey();
    const targetIndex = 50;
    await tester.pumpWidget(_ChatListHarness(
      controller: controller,
      targetKey: targetKey,
      targetIndex: targetIndex,
    ));

    controller.jumpTo(ratioOffset(controller, targetIndex));
    await tester.pump();
    centerOnTarget(controller, targetKey);
    await tester.pump();
    expect(offCenterBy(targetKey), lessThan(1.0));

    // 링크 미리보기 3개가 뒤늦게 로딩 완료 (60px 자리표시자 → 250px 카드)
    final state = tester.state<_ChatListHarnessState>(
        find.byType(_ChatListHarness));
    state.growLate(10, 190);
    state.growLate(20, 190);
    state.growLate(30, 190);
    await tester.pump();

    // 스크롤 오프셋은 그대로인데 타겟이 화면 밖으로 밀렸다 = "엉뚱한 채팅"
    expect(targetIsVisible(targetKey), isFalse,
        reason: '아래쪽 높이 변화가 타겟을 화면 밖으로 밀어낸다');

    // 반복 보정이 이걸 되돌린다
    centerOnTarget(controller, targetKey);
    await tester.pump();
    expect(offCenterBy(targetKey), lessThan(1.0));
    expect(targetIsVisible(targetKey), isTrue);
  });

  testWidgets('타겟보다 위(더 오래된) 메시지 높이 변화는 영향이 없다', (tester) async {
    final controller = ScrollController();
    final targetKey = GlobalKey();
    const targetIndex = 50;
    await tester.pumpWidget(_ChatListHarness(
      controller: controller,
      targetKey: targetKey,
      targetIndex: targetIndex,
    ));

    controller.jumpTo(ratioOffset(controller, targetIndex));
    await tester.pump();
    centerOnTarget(controller, targetKey);
    await tester.pump();

    final state = tester.state<_ChatListHarnessState>(
        find.byType(_ChatListHarness));
    state.growLate(70, 190);
    state.growLate(80, 190);
    await tester.pump();

    expect(offCenterBy(targetKey), lessThan(1.0),
        reason: '위쪽(오래된 쪽) 변화는 타겟 위치에 영향을 주지 않는다');
  });
}
