/*
 * Copyright 2025
 *
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
 *
 * Author: Niklas Andersson, niklas@niklaspandersson.se
 */

#include "renderpass.h"
#include "../image/image_kernel.h"
#include "barrier.h"
#include "device.h"
#include "pipeline.h"
#include "texture.h"

namespace caspar { namespace accelerator { namespace vulkan {

// A layer's coords are a convex polygon in fan order. They are uploaded as a triangle list,
// (0, i, i + 1) for each i, rather than drawn as a fan: Metal has no fans, and not every
// Vulkan driver on top of it emulates them (KosmicKrisp draws only the first triangle).
vk::Buffer renderpass::upload_vertex_buffers()
{
    uint32_t total_vertices = 0;
    for (auto& layer : layers_) {
        layer.vertex_buffer_offset = total_vertices * 6 * sizeof(float);
        layer.vertex_count =
            layer.coords.size() < 3 ? 0 : static_cast<uint32_t>(3 * (layer.coords.size() - 2));
        total_vertices += layer.vertex_count;
    }
    std::vector<float> fl(total_vertices * 6);

    size_t idx = 0;
    auto   put = [&](const core::frame_geometry::coord& c) {
        fl[idx * 6 + 0] = static_cast<float>(c.vertex_x);
        fl[idx * 6 + 1] = static_cast<float>(c.vertex_y);
        fl[idx * 6 + 2] = static_cast<float>(c.texture_x);
        fl[idx * 6 + 3] = static_cast<float>(c.texture_y);
        fl[idx * 6 + 4] = static_cast<float>(c.texture_r);
        fl[idx * 6 + 5] = static_cast<float>(c.texture_q);
        ++idx;
    };
    for (auto& layer : layers_) {
        for (size_t i = 1; i + 1 < layer.coords.size(); ++i) {
            put(layer.coords[0]);
            put(layer.coords[i]);
            put(layer.coords[i + 1]);
        }
    }

    return _ctx->upload_vertex_data(fl);
}

renderpass::renderpass(frame_context* ctx, uint32_t width, uint32_t height)
    : _ctx(ctx)
    , _pipeline(ctx->get_pipeline())
    , _width(width)
    , _height(height)
    , _default_attachment(ctx->create_attachment(width, height, 4))
{
    attachments_.push_back(_default_attachment);
}

renderpass::~renderpass() {}

std::shared_ptr<texture> renderpass::create_attachment(uint32_t components_count)
{
    auto attachment = _ctx->create_attachment(_width, _height, components_count);
    attachments_.push_back(attachment);
    return attachment;
}

void renderpass::draw(const draw_params& params)
{
    // Owned and handed off even when the draw is culled below: this pass's completion is what
    // releases them, so it has to come after their uploads too.
    for (const auto& tex : params.textures) {
        textures_.push_back(tex);

        // Consume the upload hand-off the transfer service stamped on this plane:
        // cross-queue ones (distance 1/2) are waited — and at distance 2 acquired —
        // by commit(); same-queue (distance 0) returns an inert token we skip.
        auto handoff = tex->take_pending_handoff();
        if (handoff)
            acquire_handoffs_.push_back({handoff, tex->id()});
    }

    auto attachment         = params.background;
    auto [coords, uniforms] = _ctx->create_draw_data(params);

    if (coords.empty()) {
        return;
    }

    std::array<vk::ImageView, 7> textures = {attachment->view(), nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};

    for (int n = 0; n < params.textures.size(); ++n) {
        textures[1 + n] = params.textures[n]->view();
    }
    if (params.local_key) {
        textures[5] = params.local_key->view();
    }
    if (params.layer_key) {
        textures[6] = params.layer_key->view();
    }

    layers_.push_back({
        attachment,
        params.local_key,
        params.layer_key,
        std::move(textures),
        std::move(coords),
        uniforms,
    });
}

void renderpass::commit()
{
    auto vertex_buffer = layers_.empty() ? vk::Buffer{} : upload_vertex_buffers();

    // One descriptor set per layer (= per draw), sized to this exact frame.
    auto descriptor_sets = _ctx->allocate_descriptor_sets(static_cast<uint32_t>(layers_.size()));

    // Cross-queue producer completions this render must wait on (the uploads it
    // samples). At distance 1/2 these are real timeline waits; the harvest skipped
    // distance-0 tokens, and record_and_submit drops any same-context token.
    std::vector<completion_token> wait_tokens;
    wait_tokens.reserve(acquire_handoffs_.size());
    for (const auto& handoff : acquire_handoffs_)
        wait_tokens.push_back(handoff.token.completion);

    _ctx->record_and_submit(
        [&](vk::CommandBuffer cmd_buffer) {
            // Acquire half of each cross-family upload hand-off, before any
            // rendering begins (a no-op below distance 2). Pairs with the release
            // recorded on the transfer queue; the wait_tokens above order it.
            for (const auto& handoff : acquire_handoffs_)
                acquire_into(cmd_buffer, handoff.token, handoff.image);

            vk::ClearValue clearColor{vk::ClearColorValue(std::array<float, 4>{0.0f, 0.0f, 0.0f, 0.0f})};

            // Viewport and scissor
            vk::Viewport viewport{0.0f, 0.0f, static_cast<float>(_width), static_cast<float>(_height), 0.0f, 1.0f};

            vk::Extent2D extent = {_width, _height};
            vk::Rect2D   scissor{{0, 0}, extent};

            auto begin_attachment = [&](const std::shared_ptr<texture>& attachment, vk::AttachmentLoadOp load_op) {
                vk::RenderingAttachmentInfo attachment_info{};
                attachment_info.imageView   = attachment->view();
                attachment_info.imageLayout = vk::ImageLayout::eRenderingLocalRead;
                attachment_info.loadOp      = load_op;
                attachment_info.storeOp     = vk::AttachmentStoreOp::eStore;
                attachment_info.clearValue  = clearColor;

                vk::RenderingInfo rendering_info{};
                rendering_info.renderArea = scissor;
                rendering_info.layerCount = 1;
                rendering_info.setColorAttachments(attachment_info);

                cmd_buffer.beginRendering(rendering_info);
                cmd_buffer.setViewport(0, viewport);
                cmd_buffer.setScissor(0, scissor);
            };

            // Done drawing into it for now: later draws sample it as a texture (a layer composited
            // with its blend mode, a key, a mix) or read it as their background.
            auto make_readable = [&](const std::shared_ptr<texture>& attachment) {
                transitionImageLayout(
                    attachment->id(),
                    vk::ImageLayout::eRenderingLocalRead,
                    vk::AccessFlagBits2::eColorAttachmentWrite | vk::AccessFlagBits2::eInputAttachmentRead,
                    vk::PipelineStageFlagBits2::eColorAttachmentOutput | vk::PipelineStageFlagBits2::eFragmentShader,
                    vk::ImageLayout::eShaderReadOnlyOptimal,
                    vk::AccessFlagBits2::eShaderRead | vk::AccessFlagBits2::eInputAttachmentRead,
                    vk::PipelineStageFlagBits2::eFragmentShader,
                    cmd_buffer);
            };

            // Drawing into it again: after any reads of it as a texture, and keeping what it holds.
            auto make_writable = [&](const std::shared_ptr<texture>& attachment) {
                transitionImageLayout(
                    attachment->id(),
                    vk::ImageLayout::eShaderReadOnlyOptimal,
                    vk::AccessFlagBits2::eColorAttachmentWrite | vk::AccessFlagBits2::eShaderRead |
                        vk::AccessFlagBits2::eInputAttachmentRead,
                    vk::PipelineStageFlagBits2::eColorAttachmentOutput | vk::PipelineStageFlagBits2::eFragmentShader,
                    vk::ImageLayout::eRenderingLocalRead,
                    vk::AccessFlagBits2::eColorAttachmentRead | vk::AccessFlagBits2::eColorAttachmentWrite |
                        vk::AccessFlagBits2::eInputAttachmentRead,
                    vk::PipelineStageFlagBits2::eColorAttachmentOutput | vk::PipelineStageFlagBits2::eFragmentShader,
                    cmd_buffer);
            };

            // Clear every attachment once, drawn into or not. Clearing on each new rendering scope
            // instead wiped a target whenever the draws came back to it (a STING over a blended layer
            // goes back and forth), and left the ones never drawn into holding whatever they held.
            for (const auto& attachment : attachments_) {
                transitionImageLayout(attachment->id(),
                                      vk::ImageLayout::eUndefined,
                                      vk::AccessFlagBits2::eNone,
                                      vk::PipelineStageFlagBits2::eTopOfPipe,
                                      vk::ImageLayout::eRenderingLocalRead,
                                      vk::AccessFlagBits2::eColorAttachmentWrite,
                                      vk::PipelineStageFlagBits2::eColorAttachmentOutput,
                                      cmd_buffer);
                begin_attachment(attachment, vk::AttachmentLoadOp::eClear);
                cmd_buffer.endRendering();
                make_readable(attachment);
            }

            std::shared_ptr<texture> previous_attachment;
            size_t                   draw_index = 0;
            for (auto& layer : layers_) {
                if (layer.attachment != previous_attachment) {
                    if (previous_attachment) {
                        cmd_buffer.endRendering();
                        make_readable(previous_attachment);
                    }
                    make_writable(layer.attachment);
                    begin_attachment(layer.attachment, vk::AttachmentLoadOp::eLoad);
                    previous_attachment = layer.attachment;
                } else {
                    // We are continuing in the same render pass, so we need a barrier to ensure the attachment is
                    // ready
                    vk::MemoryBarrier2 memoryBarrier{};
                    memoryBarrier.srcStageMask  = vk::PipelineStageFlagBits2::eColorAttachmentOutput;
                    memoryBarrier.srcAccessMask = vk::AccessFlagBits2::eColorAttachmentWrite;
                    memoryBarrier.dstStageMask  = vk::PipelineStageFlagBits2::eFragmentShader;
                    memoryBarrier.dstAccessMask = vk::AccessFlagBits2::eInputAttachmentRead;

                    vk::DependencyInfo dependencyInfo{};
                    dependencyInfo.dependencyFlags    = vk::DependencyFlagBits::eByRegion;
                    dependencyInfo.memoryBarrierCount = 1;
                    dependencyInfo.pMemoryBarriers    = &memoryBarrier;
                    cmd_buffer.pipelineBarrier2(dependencyInfo);
                }

                _pipeline->draw(cmd_buffer,
                                descriptor_sets[draw_index++],
                                vertex_buffer,
                                layer.vertex_count,
                                layer.vertex_buffer_offset,
                                layer.uniforms,
                                layer.textures);
            }

            if (previous_attachment)
                cmd_buffer.endRendering();

            // The caller finalizes the default attachment from eRenderingLocalRead, whichever target
            // the last draw went to, a key-only frame's included.
            if (previous_attachment != _default_attachment) {
                if (previous_attachment)
                    make_readable(previous_attachment);
                make_writable(_default_attachment);
            }
        },
        wait_tokens);
}

}}} // namespace caspar::accelerator::vulkan
