#import "MacarokTagBridge.h"
#include <taglib/fileref.h>
#include <taglib/flacfile.h>
#include <taglib/opusfile.h>
#include <taglib/vorbisfile.h>
#include <taglib/tpropertymap.h>
#include <taglib/tvariant.h>
#include <exception>
#include <limits>

@implementation MCTagDocument
- (instancetype)init {
    self = [super init];
    if (self) {
        _properties = @{};
        _format = @"";
    }
    return self;
}
@end

static NSString *MCString(const TagLib::String &value) {
    const auto bytes = value.to8Bit(true);
    return [[NSString alloc] initWithBytes:bytes.data()
                                  length:bytes.size()
                                encoding:NSUTF8StringEncoding] ?: @"";
}

static TagLib::String MCString(NSString *value) {
    return TagLib::String(value.UTF8String ?: "", TagLib::String::UTF8);
}

MCTagDocument *MCReadTags(NSURL *url) {
    MCTagDocument *result = [[MCTagDocument alloc] init];
    if (!url.isFileURL) {
        result.errorMessage = @"Metadata can only be read from a local audio file.";
        return result;
    }
    try {
        TagLib::FileRef file(url.fileSystemRepresentation, true, TagLib::AudioProperties::Average);
        if (file.isNull() || !file.file()->isValid()) {
            result.errorMessage = @"The file is not a supported or valid audio file.";
            return result;
        }
        NSMutableDictionary<NSString *, NSArray<NSString *> *> *properties = [NSMutableDictionary dictionary];
        const auto tags = file.properties();
        for (auto iterator = tags.begin(); iterator != tags.end(); ++iterator) {
            NSMutableArray<NSString *> *values = [NSMutableArray array];
            for (const auto &value : iterator->second) { [values addObject:MCString(value)]; }
            properties[MCString(iterator->first)] = values;
        }
        result.properties = properties;
        if (const auto audio = file.audioProperties()) {
            result.duration = audio->lengthInMilliseconds() / 1000.0;
            result.sampleRate = audio->sampleRate();
            result.channels = audio->channels();
        }
        result.format = url.pathExtension.uppercaseString;
        if (const auto flac = dynamic_cast<TagLib::FLAC::File *>(file.file())) {
            result.format = @"FLAC";
            if (const auto audio = flac->audioProperties()) { result.bitsPerSample = audio->bitsPerSample(); }
        } else if (dynamic_cast<TagLib::Ogg::Opus::File *>(file.file())) {
            result.format = @"OPUS";
        } else if (dynamic_cast<TagLib::Ogg::Vorbis::File *>(file.file())) {
            result.format = @"OGG";
        }
        const auto pictures = file.complexProperties("PICTURE");
        for (const auto &picture : pictures) {
            const auto bytes = picture["data"].toByteVector();
            if (bytes.isEmpty()) { continue; }
            const bool front = picture["pictureType"].toString() == "Front Cover";
            if (!result.artworkData || front) {
                result.artworkData = [NSData dataWithBytes:bytes.data() length:bytes.size()];
                result.artworkMIMEType = MCString(picture["mimeType"].toString());
            }
            if (front) { break; }
        }
    } catch (const std::exception &) {
        result.errorMessage = @"TagLib could not read the audio metadata.";
    } catch (...) {
        result.errorMessage = @"The audio metadata could not be read.";
    }
    return result;
}

NSString *MCWriteTags(NSURL *url, NSDictionary<NSString *, NSString *> *edits,
                      NSData *artworkData, NSString *artworkMIMEType) {
    if (!url.isFileURL) { return @"Metadata can only be written to a local audio file."; }
    try {
        TagLib::FileRef file(url.fileSystemRepresentation, true);
        if (file.isNull() || !file.file()->isValid()) { return @"The file does not support metadata editing."; }
        auto properties = file.properties();
        for (NSString *rawKey in edits) {
            const auto key = MCString(rawKey.uppercaseString);
            NSString *value = edits[rawKey];
            if (value.length == 0) { properties.erase(key); }
            else { properties[key] = TagLib::StringList(MCString(value)); }
        }
        const auto unsupported = file.setProperties(properties);
        for (NSString *rawKey in edits) {
            if (unsupported.contains(MCString(rawKey.uppercaseString))) {
                return [NSString stringWithFormat:@"This file format cannot store the %@ tag.", rawKey];
            }
        }
        if (artworkData) {
            if (artworkData.length > std::numeric_limits<unsigned int>::max()) {
                return @"The artwork image is too large.";
            }
            TagLib::List<TagLib::VariantMap> pictures;
            TagLib::VariantMap front;
            front["data"] = TagLib::ByteVector(static_cast<const char *>(artworkData.bytes),
                                               static_cast<unsigned int>(artworkData.length));
            front["pictureType"] = "Front Cover";
            front["mimeType"] = MCString(artworkMIMEType ?: @"image/jpeg");
            front["description"] = "Album cover";
            pictures.append(front);
            for (const auto &existing : file.complexProperties("PICTURE")) {
                if (existing["pictureType"].toString() != "Front Cover") { pictures.append(existing); }
            }
            if (!file.setComplexProperties("PICTURE", pictures)) {
                return @"This file format cannot embed album artwork.";
            }
        }
        if (!file.save()) { return @"TagLib could not save changes to the audio file."; }
    } catch (const std::exception &) {
        return @"TagLib could not write the audio metadata.";
    } catch (...) {
        return @"The audio metadata could not be written.";
    }
    return nil;
}
