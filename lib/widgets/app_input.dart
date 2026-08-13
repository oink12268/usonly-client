import 'package:flutter/material.dart';

/// 앱 공통 입력 필드 스타일.
///
/// 각진 아웃라인(`OutlineInputBorder`) 대신 은은하게 채워진 라운드 박스를 쓰고,
/// 포커스가 갔을 때만 얇은 primary 링이 나타난다. 채팅 입력바와 같은 톤이라
/// 앱 전체(다이얼로그·폼·검색바)가 하나의 흑백 미니멀 언어로 묶인다.
///
/// 기본값은 [AppInput.theme]으로 `ThemeData.inputDecorationTheme`에 걸려 있으므로
/// 대부분의 `TextField`는 `decoration`을 따로 주지 않아도 이 스타일을 따른다.
/// 라벨이 필요하면 `labelText` 대신 [AppTextField]의 `label`을 써서 필드 위에
/// 작은 캡션으로 올린다. (`labelText`의 플로팅 라벨이 이 톤에서 제일 올드해
/// 보이는 부분이다. 다만 `floatingLabelBehavior`를 전역으로 끄지는 않는다 —
/// `showDatePicker`의 키보드 입력 모드처럼 프레임워크가 직접 만드는 필드는
/// `labelText`로 날짜 형식을 안내하기 때문에 그건 살려둔다.)
class AppInput {
  const AppInput._();

  /// 기본 모서리 반경. 검색바처럼 알약 모양이 필요하면 [decoration]에서 덮어쓴다.
  static const double radius = 14;

  static const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 16, vertical: 14);
  static const EdgeInsets densePadding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);

  /// 입력 필드 배경.
  ///
  /// 라이트에서는 흰 면 + 실낱같은 테두리로 띄우고, 다크에서는 테두리 없이
  /// 배경보다 한 톤 밝은 면으로 띄운다. 다이얼로그처럼 회색 면 위에 올라가도
  /// 필드가 묻히지 않는다.
  static Color fill(ColorScheme cs) => cs.brightness == Brightness.light
      ? cs.surfaceContainerLowest
      : cs.surfaceContainerHighest;

  /// 포커스가 없을 때의 테두리. 다크에서는 없음.
  static BorderSide restSide(ColorScheme cs) => cs.brightness == Brightness.light
      ? BorderSide(color: cs.outlineVariant)
      : BorderSide.none;

  static OutlineInputBorder _border(double r, [BorderSide side = BorderSide.none]) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(r), borderSide: side);

  /// `ThemeData.inputDecorationTheme`에 넣는 전역 기본값.
  static InputDecorationThemeData theme(ColorScheme cs) => InputDecorationThemeData(
        filled: true,
        fillColor: fill(cs),
        hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.38)),
        prefixIconColor: cs.onSurfaceVariant,
        suffixIconColor: cs.onSurfaceVariant,
        counterStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
        contentPadding: padding,
        border: _border(radius, restSide(cs)),
        enabledBorder: _border(radius, restSide(cs)),
        disabledBorder: _border(radius, restSide(cs)),
        focusedBorder: _border(radius, BorderSide(color: cs.primary, width: 1.5)),
        errorBorder: _border(radius, BorderSide(color: cs.error, width: 1.5)),
        focusedErrorBorder: _border(radius, BorderSide(color: cs.error, width: 1.5)),
      );

  /// 전역 테마 위에 얹는 개별 데코레이션. 반경/여백만 바꾸고 싶을 때 쓴다.
  static InputDecoration decoration(
    BuildContext context, {
    String? hint,
    Widget? prefixIcon,
    Widget? suffixIcon,
    bool dense = false,
    double? radius,
    String? counterText,
    EdgeInsetsGeometry? contentPadding,
  }) {
    final cs = Theme.of(context).colorScheme;
    final r = radius ?? AppInput.radius;
    return InputDecoration(
      hintText: hint,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      counterText: counterText,
      isDense: dense,
      contentPadding: contentPadding ?? (dense ? densePadding : padding),
      border: _border(r, restSide(cs)),
      enabledBorder: _border(r, restSide(cs)),
      disabledBorder: _border(r, restSide(cs)),
      focusedBorder: _border(r, BorderSide(color: cs.primary, width: 1.5)),
      errorBorder: _border(r, BorderSide(color: cs.error, width: 1.5)),
      focusedErrorBorder: _border(r, BorderSide(color: cs.error, width: 1.5)),
    );
  }
}

/// 입력 필드 위에 올리는 작은 캡션 라벨.
class AppInputLabel extends StatelessWidget {
  final String text;

  const AppInputLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.1,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 앱 표준 텍스트 입력. [label]을 주면 필드 위에 캡션으로 붙는다.
class AppTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final bool autofocus;
  final bool dense;
  final bool showCounter;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.autofocus = false,
    this.dense = false,
    this.showCounter = false,
    this.prefixIcon,
    this.suffixIcon,
    this.focusNode,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      maxLines: maxLines,
      minLines: minLines,
      maxLength: maxLength,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      style: style,
      cursorColor: Theme.of(context).colorScheme.primary,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: AppInput.decoration(
        context,
        hint: hint,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        dense: dense,
        counterText: maxLength != null && !showCounter ? '' : null,
      ),
    );

    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [AppInputLabel(label!), field],
    );
  }
}
