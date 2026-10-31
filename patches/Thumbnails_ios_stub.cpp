// iOS build of GCode/Thumbnails.cpp (replaces it via prusaslicer_ios.patch).
// PNG thumbnails and the `thumbnails` setting parser are upstream's code
// (PrusaSlicer 2.9.6); JPEG (libjpeg) and QOI encoding aren't built for iOS
// and return an empty buffer, so those formats are skipped.
#include "Thumbnails.hpp"

#include <boost/algorithm/string/case_conv.hpp>
#include <boost/log/trivial.hpp>
#include <string>
#include <cstdint>

#include "libslic3r/miniz_extension.hpp" // IWYU pragma: keep
#include "../format.hpp"
#include "libslic3r/Config.hpp"
#include "libslic3r/GCode/ThumbnailData.hpp"
#include "libslic3r/Point.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "miniz.h"

namespace Slic3r::GCodeThumbnails {

using namespace std::literals;

struct CompressedPNG : CompressedImageBuffer
{
    ~CompressedPNG() override { if (data) mz_free(data); }
    std::string_view tag() const override { return "thumbnail"sv; }
};

struct EmptyBuffer : CompressedImageBuffer
{
    ~EmptyBuffer() override = default;
    std::string_view tag() const override { return "thumbnail"sv; }
};

std::unique_ptr<CompressedImageBuffer> compress_thumbnail_png(const ThumbnailData &data)
{
    auto out = std::make_unique<CompressedPNG>();
    out->data = tdefl_write_image_to_png_file_in_memory_ex((const void*)data.pixels.data(), data.width, data.height, 4, &out->size, MZ_DEFAULT_LEVEL, 1);
    return out;
}

std::unique_ptr<CompressedImageBuffer> compress_thumbnail(const ThumbnailData &data, GCodeThumbnailsFormat format)
{
    if (format == GCodeThumbnailsFormat::PNG)
        return compress_thumbnail_png(data);
    return std::make_unique<EmptyBuffer>();   // JPG / QOI: not built for iOS
}

std::pair<GCodeThumbnailDefinitionsList, ThumbnailErrors> make_and_check_thumbnail_list(const std::string& thumbnails_string, const std::string_view def_ext /*= "PNG"sv*/)
{
    if (thumbnails_string.empty())
        return {};

    std::istringstream is(thumbnails_string);
    std::string point_str;

    ThumbnailErrors errors;

    // generate thumbnails data to process it

    GCodeThumbnailDefinitionsList thumbnails_list;
    while (std::getline(is, point_str, ',')) {
        Vec2d point(Vec2d::Zero());
        GCodeThumbnailsFormat format;
        std::istringstream iss(point_str);
        std::string coord_str;
        if (std::getline(iss, coord_str, 'x') && !coord_str.empty()) {
            std::istringstream(coord_str) >> point(0);
            if (std::getline(iss, coord_str, '/') && !coord_str.empty()) {
                std::istringstream(coord_str) >> point(1);

                if (0 < point(0) && point(0) < 1000 && 0 < point(1) && point(1) < 1000) {
                    std::string ext_str;
                    std::getline(iss, ext_str, '/');

                    if (ext_str.empty())
                        ext_str = def_ext.empty() ? "PNG"sv : def_ext;

                    // check validity of extention
                    boost::to_upper(ext_str);
                    if (!ConfigOptionEnum<GCodeThumbnailsFormat>::from_string(ext_str, format)) {
                        format = GCodeThumbnailsFormat::PNG;
                        errors = enum_bitmask(errors | ThumbnailError::InvalidExt);
                    }

                    thumbnails_list.emplace_back(std::make_pair(format, point));
                }
                else
                    errors = enum_bitmask(errors | ThumbnailError::OutOfRange);
                continue;
            }
        }
        errors = enum_bitmask(errors | ThumbnailError::InvalidVal);
    }

    return std::make_pair(std::move(thumbnails_list), errors);
}

std::pair<GCodeThumbnailDefinitionsList, ThumbnailErrors> make_and_check_thumbnail_list(const ConfigBase& config)
{
    // ??? Unit tests or command line slicing may not define "thumbnails" or "thumbnails_format".
    // ??? If "thumbnails_format" is not defined, export to PNG.

    // generate thumbnails data to process it

    if (const auto thumbnails_value = config.option<ConfigOptionString>("thumbnails"))
        return make_and_check_thumbnail_list(thumbnails_value->value);

    return {};
}

std::string get_error_string(const ThumbnailErrors& errors)
{
    std::string error_str;

    if (errors.has(ThumbnailError::InvalidVal))
        error_str += "\n - " + format("Invalid input format. Expected vector of dimensions in the following format: \"%1%\"", "XxY/EXT, XxY/EXT, ...");
    if (errors.has(ThumbnailError::OutOfRange))
        error_str += "\n - Input value is out of range";
    if (errors.has(ThumbnailError::InvalidExt))
        error_str += "\n - Some extension in the input is invalid";

    return error_str;
}

} // namespace Slic3r::GCodeThumbnails
