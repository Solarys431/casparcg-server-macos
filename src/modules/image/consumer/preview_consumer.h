/*
 * This file is part of CasparCG (www.casparcg.com).
 *
 * CasparCG is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * CasparCG is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with CasparCG. If not, see <http://www.gnu.org/licenses/>.
 */

#pragma once

#include <core/consumer/frame_consumer.h>
#include <core/fwd.h>

#include <boost/property_tree/ptree_fwd.hpp>

#include <string>
#include <vector>

namespace caspar::image {

// A small picture of the channel and its audio peaks, for a client on the same machine: every frame, scaled down to
// 640 wide, with the loudness blocks of EBU R 128, in POSIX shared memory: /vtx-pv-<channel>, or /vtx-pv-<name>.
// See preview_consumer.cpp for the layout (version 2).
spl::shared_ptr<core::frame_consumer>
create_preview_consumer(const std::vector<std::wstring>&                         params,
                        const core::video_format_repository&                     format_repository,
                        const std::vector<spl::shared_ptr<core::video_channel>>& channels,
                        const core::channel_info&                                channel_info);

spl::shared_ptr<core::frame_consumer>
create_preconfigured_preview_consumer(const boost::property_tree::wptree&                      ptree,
                                      const core::video_format_repository&                     format_repository,
                                      const std::vector<spl::shared_ptr<core::video_channel>>& channels,
                                      const core::channel_info&                                channel_info);

} // namespace caspar::image
