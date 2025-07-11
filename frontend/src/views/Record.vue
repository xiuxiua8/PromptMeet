<template>
  <el-timeline style="max-width:475px">
    <el-timeline-item v-for="(msg, index) in chatHistory" :key="index" timestamp={{msg.timestamp}} placement="top">
      <el-card>
        <p>{{ msg.content }}</p>
      </el-card>
    </el-timeline-item>
  </el-timeline>
</template>

<style scoped>

</style>
