import Foundation

enum ImportError: Error {
  case failed(String)
  case http(Int)
  case noRelease
  case crashed(String)
  case exited(String)
}

/// The sentences the person reads when an import, a conversion or a move fails.
enum ErrorWords {
  /// nil for a failure of another kind, which the caller words itself.
  static func explain(_ error: Error) -> String? {
    switch error {
    case is CancellationError:
      return "отменено"
    case let error as ImportError:
      return converter(error)
    case let error as ScaledCheckpoint.Failure:
      return scaled(error)
    case let error as ModelMover.Failure:
      return mover(error)
    default:
      return nil
    }
  }

  /// For an error nobody above knows: the LoRA that fits no model, or the system's own words.
  static func fallback(_ error: Error) -> String {
    let text = String(describing: error)
    if text.contains("versionDetectionFailed") || text.contains("modelVersionFailed") {
      return "не понятно, для какой модели эта LoRA. Выберите модель того же семейства и повторите"
    }
    return error.localizedDescription
  }

  static func noSpace(_ gigabytes: Double) -> String {
    String(format: "на диске нужно хотя бы %.0f ГБ свободного места", gigabytes)
  }

  private static func converter(_ error: ImportError) -> String {
    switch error {
    case .failed(let reason):
      return reason
    case .http(let code):
      return "конвертер не скачался, GitHub ответил \(code)"
    case .noRelease:
      return "на GitHub не нашёлся выпуск движка с конвертером"
    case .crashed(let text):
      return "конвертер упал на этом файле: такую модель он пока не умеет" + lastLine(text)
    case .exited(let text):
      let lower = text.lowercased()
      if lower.contains("no space") { return "на диске не хватило места" }
      if ["versiondetection", "tensornotfound", "datanotfound", "unsupported"].contains(where: lower.contains) {
        return "движок не узнал этот файл: это не целая модель или её семейство ему неизвестно"
      }
      return lastLine(text).isEmpty ? "конвертер завершился с ошибкой" : lastLine(text)
    }
  }

  private static func scaled(_ error: ScaledCheckpoint.Failure) -> String {
    switch error {
    case .unsupported(let what):
      return "веса ужаты способом, который движок пока не читает: \(what). Нужна версия fp8 или fp16"
    case .unreadable:
      return "файл не читается, возможно он скачался не до конца"
    case .noSpace(let gigabytes):
      return noSpace(gigabytes)
    }
  }

  private static func mover(_ error: ModelMover.Failure) -> String {
    switch error {
    case .unreachable(let disk):
      return "диск «\(disk)» не подключён"
    case .noSpace(let gigabytes):
      return String(format: "не хватает места: нужно %.0f ГБ", gigabytes)
    case .mismatch(let file):
      return "\(file) скопировался не целиком, оригинал не тронут"
    case .notLinked(let file):
      return "\(file) и так на Mac"
    }
  }

  /// " (last line)" of a tool's log, or nothing.
  static func lastLine(_ text: String) -> String {
    let line =
      text.split(whereSeparator: \.isNewline).last.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    return line.isEmpty ? "" : " (\(line))"
  }
}
