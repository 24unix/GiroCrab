// UI language (LanguagePreference.swift): German source texts, English from the Mac app's
// string catalog (build.rs → OUT_DIR/en.json, looked up in src/i18n.rs). The choice
// ("system", "de", "en") lives in QSettings (key `language`, ~/.config/GiroCrab/GiroCrab.conf)
// and takes effect after a restart, so one run never mixes languages.
#include <QtCore/QCoreApplication>
#include <QtCore/QLocale>
#include <QtCore/QSettings>
#include <QtCore/QStringList>
#include <QtCore/QTranslator>
#include <QtCore/QVariant>

// src/i18n.rs: English for a German source text, null if there is none.
extern "C" const char *girocrab_tr(const char *german);

namespace {

const QString kLanguageKey = QStringLiteral("language");

// qsTr / QCoreApplication::translate: the context is ignored, the German text is the key.
// A text without English stays as written: our German source, or the English source of
// Qt's own texts ("Ctrl" in shortcuts), which the desktop's Qt translations (KDE loads
// qtbase_de for a German system) would otherwise turn into German.
class CatalogTranslator : public QTranslator
{
public:
    using QTranslator::QTranslator;
    QString translate(const char *, const char *sourceText, const char *, int) const override
    {
        if (!sourceText)
            return QString();
        const char *en = girocrab_tr(sourceText);
        return QString::fromUtf8(en ? en : sourceText);
    }
    bool isEmpty() const override { return false; }
};

} // namespace

extern "C" void girocrab_acknowledge_system_language();
extern "C" const char *girocrab_system_language();

// LanguagePreference.choice: "system", "de" or "en".
extern "C" const char *girocrab_language_choice()
{
    const QString v = QSettings().value(kLanguageKey).toString();
    if (v == QLatin1String("de"))
        return "de";
    if (v == QLatin1String("en"))
        return "en";
    return "system";
}

// LanguagePreference.apply: stored at once (the restart reads it).
extern "C" void girocrab_set_language_choice(const char *choice)
{
    QSettings settings;
    const QString v = QString::fromUtf8(choice);
    if (v == QLatin1String("de") || v == QLatin1String("en"))
        settings.setValue(kLanguageKey, v);
    else
        settings.remove(kLanguageKey);
    settings.sync();
    girocrab_acknowledge_system_language(); // LanguagePreference.apply
}

namespace {

const QString kLastSystemKey = QStringLiteral("language.lastSystemLanguage");

/// "de-DE" → "de"; empty for languages the app has no translation for.
QString supportedCode(const QString &tag)
{
    const QString code = tag.section(QLatin1Char('-'), 0, 0).section(QLatin1Char('_'), 0, 0).toLower();
    return code == QLatin1String("de") || code == QLatin1String("en") ? code : QString();
}

/// LanguagePreference.systemIsSupported: the desktop's list contains a language the app speaks.
bool systemIsSupported()
{
    for (const QString &tag : QLocale::system().uiLanguages())
        if (!supportedCode(tag).isEmpty())
            return true;
    return false;
}

/// LanguagePreference.systemKey: the resolved system language, or "-" + the raw first entry
/// when the system speaks none of the app's languages.
QString systemKey()
{
    if (systemIsSupported())
        return QString::fromLatin1(girocrab_system_language());
    const QStringList list = QLocale::system().uiLanguages();
    return QLatin1Char('-') + (list.isEmpty() ? QString() : list.first());
}

} // namespace

// LanguagePreference.systemLanguage: the first entry of the desktop's language list
// (LANGUAGE, LC_ALL, LC_MESSAGES, LANG) the app speaks, German if there is none (the
// language screen before the vault opens asks in that case, see girocrab_language_question).
extern "C" const char *girocrab_system_language()
{
    for (const QString &tag : QLocale::system().uiLanguages()) {
        const QString code = supportedCode(tag);
        if (code == QLatin1String("de"))
            return "de";
        if (code == QLatin1String("en"))
            return "en";
    }
    return "de";
}

// LanguagePreference.acknowledgeSystemLanguage: remembers the current system language, so a
// question about it is asked once.
extern "C" void girocrab_acknowledge_system_language()
{
    QSettings settings;
    settings.setValue(kLastSystemKey, systemKey());
    settings.sync();
}

// LanguagePreference.startupQuestion: only on the first start or after the system language
// changed. "none", "choose" (the system speaks neither language) or "changed:<code>" (the
// system moved away from an explicitly chosen language). Cases without a question are
// acknowledged at once.
extern "C" const char *girocrab_language_question()
{
    const QSettings settings;
    const QVariant last = settings.value(kLastSystemKey);
    if (last.isValid() && last.toString() == systemKey())
        return "none";
    const QString choice = QString::fromLatin1(girocrab_language_choice());
    const QString system = QString::fromLatin1(girocrab_system_language());
    if (choice == QLatin1String("system") && !systemIsSupported())
        return "choose";
    if (choice != QLatin1String("system") && last.isValid() && systemIsSupported() && choice != system)
        return system == QLatin1String("en") ? "changed:en" : "changed:de";
    girocrab_acknowledge_system_language();
    return "none";
}

// Called once before the QML engine loads. English: the catalog translator. Both: the
// default QLocale (Qt.locale() in Fmt.qml) speaks the UI language with the system's region,
// like Locale.autoupdatingCurrent on the Mac ("en_DE" for English on a German system).
extern "C" void girocrab_apply_language(const char *code)
{
    const bool english = qstrcmp(code, "en") == 0;
    if (english)
        QCoreApplication::installTranslator(new CatalogTranslator(QCoreApplication::instance()));
    const QLocale system = QLocale::system();
    const QLocale::Language language = english ? QLocale::English : QLocale::German;
    QLocale locale(language, system.territory());
    if (locale.language() != language)
        locale = QLocale(language);
    QLocale::setDefault(locale);
}
