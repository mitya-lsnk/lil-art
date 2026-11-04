import Foundation
import Testing
@testable import LilArtCore

@Suite struct ErrorWordsTests {
  @Test func aStoppedJobSaysCancelled() {
    #expect(ErrorWords.explain(CancellationError()) == "отменено")
  }

  @Test func theConverterToolsFailuresAreExplained() {
    #expect(ErrorWords.explain(ImportError.failed("своя причина")) == "своя причина")
    #expect(ErrorWords.explain(ImportError.http(403)) == "конвертер не скачался, GitHub ответил 403")
    #expect(ErrorWords.explain(ImportError.noRelease) == "на GitHub не нашёлся выпуск движка с конвертером")
  }

  @Test func aCrashQuotesTheLastLineOfItsLog() {
    #expect(ErrorWords.explain(ImportError.crashed("start\nFatal error: x\n"))
      == "конвертер упал на этом файле: такую модель он пока не умеет (Fatal error: x)")
    #expect(ErrorWords.explain(ImportError.crashed("")) == "конвертер упал на этом файле: такую модель он пока не умеет")
  }

  @Test func anExitIsReadFromWhatTheToolPrinted() {
    #expect(ErrorWords.explain(ImportError.exited("write failed: No space left on device"))
      == "на диске не хватило места")
    for text in ["versionDetectionFailed", "TensorNotFound(x)", "dataNotFound", "unsupported dtype"] {
      #expect(ErrorWords.explain(ImportError.exited(text))
        == "движок не узнал этот файл: это не целая модель или её семейство ему неизвестно", "\(text)")
    }
    #expect(ErrorWords.explain(ImportError.exited("one\ntwo")) == " (two)")
    #expect(ErrorWords.explain(ImportError.exited("")) == "конвертер завершился с ошибкой")
  }

  @Test func fp8FileProblemsAreExplained() {
    #expect(ErrorWords.explain(ScaledCheckpoint.Failure.unsupported("nvfp4"))
      == "веса ужаты способом, который движок пока не читает: nvfp4. Нужна версия fp8 или fp16")
    #expect(ErrorWords.explain(ScaledCheckpoint.Failure.unreadable)
      == "файл не читается, возможно он скачался не до конца")
    #expect(ErrorWords.explain(ScaledCheckpoint.Failure.noSpace(41.6))
      == "на диске нужно хотя бы 42 ГБ свободного места")
  }

  @Test func movingToADiskIsExplained() {
    #expect(ErrorWords.explain(ModelMover.Failure.unreachable("T7")) == "диск «T7» не подключён")
    #expect(ErrorWords.explain(ModelMover.Failure.noSpace(12.2)) == "не хватает места: нужно 12 ГБ")
    #expect(ErrorWords.explain(ModelMover.Failure.mismatch("a.ckpt")) == "a.ckpt скопировался не целиком, оригинал не тронут")
    #expect(ErrorWords.explain(ModelMover.Failure.notLinked("a.ckpt")) == "a.ckpt и так на Mac")
  }

  @Test func anErrorOfAnotherKindIsLeftToTheCaller() {
    struct Other: Error {}
    #expect(ErrorWords.explain(Other()) == nil)
  }

  @Test func theFallbackRecognisesALoraForNoKnownModel() {
    struct versionDetectionFailed: Error {}
    #expect(ErrorWords.fallback(versionDetectionFailed())
      == "не понятно, для какой модели эта LoRA. Выберите модель того же семейства и повторите")
    #expect(ErrorWords.fallback(URLError(.notConnectedToInternet)) == URLError(.notConnectedToInternet).localizedDescription)
  }
}
