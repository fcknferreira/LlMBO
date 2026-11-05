import CoreAudio
// Imprime a saída de áudio padrão: nome, volume, mudo e se está tocando ("rodando").
var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
var name: Unmanaged<CFString>?; size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name)
func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var v = UInt32(0); var s = UInt32(4); var ad = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(id, &ad, 0, nil, &s, &v); return v
}
print("saída=\"\(name?.takeRetainedValue() as String? ?? "?")\" mudo=\(u32(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)) tocando=\(u32(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal))")
